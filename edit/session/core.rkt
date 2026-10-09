#lang racket

;;; edit/session/core.rkt —— core 边界：文档 / 视图 / 几何 / 渲染 / 读 + 内核适配
;;;
;;; **唯一 require core/editor 的模块**。其余 session-* / feature / document 都只走本模块的
;;; 适配函数（session-ed-* / session-view-* / session-document-*），不直接碰 core。
;;;
;;; 提供：
;;;     · session-blank
;;;     · 几何：layout-place -> placed / rectangle；渲染：core 合成 + 增量
;;;     · 文档 / 视图结构 + 读 + 文档键表
;;;     · 内核适配：把 core 的编辑 / 导航 / 剪贴板 / 命中换算包成 session 变换

(require "value.rkt"
         "doc.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/point.rkt"
         racket/string
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt"
         "../core/face.rkt")

(provide
 session-blank
 ;; 面板文档构造（面板 = 只读、带 face 的文档）
 panel-doc
 ;; 几何 / 渲染
 session-views session-panes session-rectangles session-patch sync-layout!
 ;; session-patch 的产物词汇（piece）—— 由核心重导，后端不必下钻到 view/patch
 piece piece? piece-row piece-column piece-text piece-attr
 session-focused-did
 ;; 文档 / 视图结构 + 读
 session-add-document session-add-view
 session-document-ids session-view-ids-of session-document-name
 session-float-dids
 session-view-did session-view-point session-view-point-line
 session-view-point-column session-view-point->screen session-view-cursor-screen
 session-view-width session-view-height session-view-line-numbers? session-view-string
 session-view-id-list session-document-view-list
 session-document-handle
 ;; 保存句柄 / 脏
 session-document-string session-mark-saved session-dirty?
 ;; 写回原语（face；插件层用）
 session-doc-face!
 ;; 按 vid 的区间替换（补全接受等）
 session-ed-replace!
 ;; 内核适配
 session-ed-close-view session-ed-close-document
 session-ed-assign! session-ed-set-point! session-ed-screen->point
 session-ed-scroll! session-ed-nav!
 session-ed-select-all! session-ed-copy! session-ed-cut! session-ed-paste!
 session-ed-insert! session-ed-delete! session-ed-backspace!
 session-ed-undo! session-ed-redo!)

;;; ---------- 空会话 ----------

(define (session-blank width height [keys '()])
  (session-new (make-blank-editor) #f #f (focus-new #f) width height keys))

;;; ---------- 面板文档 ----------

;; rows : (listof (list 文本 face|#f))
;; → 只读文档：逐行文本 + face（face=#f 的行用默认）。所有面板内容生成共用这一处。
(define (panel-doc rows)
  (define lines (for/list ([r (in-list rows)]) (first r)))
  (define doc (document-open (string-join lines "\n")))
  (document-face-fill-batch
   doc (for/list ([r (in-list rows)] [l (in-list lines)] [i (in-naturals)]
                  #:when (second r))
         (list i 0 i (string-length l) (second r))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l) #t)))
  doc)

;;; ---------- 几何 ----------

(define (session-views s)
  (layout-place (session-layout s) (session-bindings s)
                (lambda (vid) (session-visible? s vid))
                (area 0 0 (session-width s) (session-height s))))

(define (session-rectangles s)
  (for/list ([p (in-list (session-panes s))])
    (rectangle (placed-vid p) (placed-x p) (placed-y p) (placed-w p) (placed-h p)
               (placed-deep p))))

;; 浮层 → placed（deep 用 float 自带的）。
(define (session-float-placed s)
  (for/list ([f (in-list (session-floats s))])
    (placed (float-vid f) (float-x f) (float-y f) (float-w f) (float-h f) (float-deep f))))

;; 所有已落位窗格：布局树 + 浮层，按 deep 升序（大的在上）。
(define (session-panes s)
  (sort (append (session-views s) (session-float-placed s)) < #:key placed-deep))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

;; 本帧几何落到各 view 的视口尺寸（ensure / 上下移动用；幂等）。
(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 渲染 ----------

(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)))

;;; ---------- 文档 / 视图结构 ----------

(define (session-add-document s doc width height
                              #:name [name "*scratch*"]
                              #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (define-values (ed** vid) (editor-add-view ed* did width height
                                             #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s
            [ed ed**]
            [doc-keymaps (hash-set (session-doc-keymaps s) did (kbd))])
          did vid))

(define (session-add-view s did width height
                          #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* vid) (editor-add-view (session-ed s) did width height
                                            #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s [ed ed*]) vid))

;;; ---------- 读 ----------

(define (session-document-ids s) (editor-document-id-list (session-ed s)))
(define (session-view-ids-of s did) (editor-document-view-list (session-ed s) did))
(define (session-document-name s did) (editor-document-name (session-ed s) did))
(define (session-view-did s vid) (editor-view-document-id (session-ed s) vid))
(define (session-view-point s vid) (editor-view-point (session-ed s) vid))
(define (session-view-point-line s vid) (editor-view-point-line (session-ed s) vid))
(define (session-view-point-column s vid) (editor-view-point-column (session-ed s) vid))

;; 某视图某点的**绝对屏幕坐标**（列, 行）；不在视口内→ (#f #f)。
(define (session-view-point->screen s vid line col)
  (define pl (for/first ([p (in-list (session-views s))] #:when (eqv? vid (placed-vid p))) p))
  (cond
    [(not pl) (values #f #f)]
    [else
     (define-values (r c) (editor-view-point->screen-position (session-ed s) vid (point line col)))
     (if r (values (+ (placed-x pl) c) (+ (placed-y pl) r)) (values #f #f))]))

;; 某视图光标的绝对屏幕坐标（列, 行）。补全弹窗锚点用。
(define (session-view-cursor-screen s vid)
  (session-view-point->screen s vid (session-view-point-line s vid)
                              (session-view-point-column s vid)))

(define (session-float-dids s)
  (for/list ([f (in-list (session-floats s))]) (session-view-did s (float-vid f))))
(define (session-view-width s vid) (editor-view-width (session-ed s) vid))
(define (session-view-height s vid) (editor-view-height (session-ed s) vid))
(define (session-view-line-numbers? s vid) (editor-view-line-numbers? (session-ed s) vid))
(define (session-view-string s vid) (editor-view-string (session-ed s) vid))
(define (session-view-id-list s) (editor-view-id-list (session-ed s)))
(define (session-document-view-list s did) (editor-document-view-list (session-ed s) did))
(define (session-document-string s did) (editor-document-string (session-ed s) did))
(define (session-document-handle s did) (editor-document-handle (session-ed s) did))

;;; ---------- 写回原语 ----------

;; 用 fills 重设某文档的 face 端口：先清空（整篇 #f），再按 fills 逐格 face-compose。
(define (session-doc-face! s did fills)
  (define doc (session-document-handle s did))
  (document-set-face! doc #f)
  (document-face-fill-batch* doc fills face-compose)
  s)

;; 把 vid 的 [l0 c0, l1 c1) 替换成 text（选区 + 插入）。
(define (session-ed-replace! s vid l0 c0 l1 c1 text)
  (define ed (session-ed s))
  (editor-view-set-selections! ed vid (selections-one (selection (point l0 c0) (point l1 c1))))
  (editor-view-insert! ed vid text)
  s)

;;; ---------- 保存句柄 / 脏 ----------

;; 记录「已保存」句柄；核心文档不可变，之后编辑会产生新句柄 → 脏。
(define (session-mark-saved s did)
  (session-set-saved s did (editor-document-handle (session-ed s) did)))

;; 脏 = 有 saved 且当前句柄 != saved（undo 回保存点若命中同一快照会自动变干净）。
(define (session-dirty? s did)
  (define saved (session-saved s did))
  (and saved (not (eq? (editor-document-handle (session-ed s) did) saved))))

;;; ---------- 内核适配（唯一碰 core/editor 的地方） ----------

(define (session-ed-close-view s vid)
  (struct-copy session s [ed (editor-close-view (session-ed s) vid)]))
(define (session-ed-close-document s did)
  (struct-copy session s [ed (editor-close-document (session-ed s) did)]))

(define (session-ed-assign! s vid doc)
  (editor-view-assign! (session-ed s) vid doc) s)
(define (session-ed-set-point! s vid line col)
  (editor-view-set-point! (session-ed s) vid (point line col)) s)
(define (session-ed-screen->point s vid row col)
  (editor-view-screen-position->point (session-ed s) vid row col))

(define (session-ed-scroll! s vid n) (editor-view-scroll! (session-ed s) vid n) s)
(define (session-ed-nav! s vid dir extend?)
  (define ed (session-ed s))
  (case dir
    [(left)  (editor-view-left! ed vid extend?)]
    [(right) (editor-view-right! ed vid extend?)]
    [(up)    (editor-view-up! ed vid extend?)]
    [(down)  (editor-view-down! ed vid extend?)]
    [(home)  (editor-view-home! ed vid extend?)]
    [(end)   (editor-view-end! ed vid extend?)]
    [else (error 'session-ed-nav "未知方向: ~a（left/right/up/down/home/end）" dir)])
  s)

(define (session-ed-select-all! s vid) (editor-view-select-all! (session-ed s) vid) s)
(define (session-ed-copy! s vid) (editor-view-copy! (session-ed s) vid) s)
(define (session-ed-cut! s vid) (editor-view-cut! (session-ed s) vid) s)
(define (session-ed-paste! s vid) (editor-view-paste! (session-ed s) vid) s)

(define (session-ed-insert! s vid text) (editor-view-insert! (session-ed s) vid text) s)
(define (session-ed-delete! s vid) (editor-view-delete! (session-ed s) vid) s)
(define (session-ed-backspace! s vid) (editor-view-backspace! (session-ed s) vid) s)
(define (session-ed-undo! s vid) (editor-view-undo! (session-ed s) vid) s)
(define (session-ed-redo! s vid) (editor-view-redo! (session-ed s) vid) s)
