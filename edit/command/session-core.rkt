#lang racket

;;; edit/command/session-core.rkt —— core 边界：文档 / 视图 / 几何 / 渲染 / 读 + 内核适配
;;;
;;; **唯一 require core/editor 的模块**。其余 session-* / feature / document 都只走本模块的
;;; 适配函数（session-ed-* / session-view-* / session-document-*），不直接碰 core。
;;;
;;; 提供：
;;;     · session-blank
;;;     · 几何：layout-place -> placed / rectangle；渲染：core 合成 + 增量
;;;     · 文档 / 视图结构 + 读 + 文档键表
;;;     · 内核适配：把 core 的编辑 / 导航 / 剪贴板 / 命中换算包成 session 变换

(require "session-value.rkt"
         "session-doc.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/point.rkt"
         racket/string
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt")

(provide
 session-blank
 ;; 面板文档构造（面板 = 只读、带 face 的文档）
 panel-doc
 ;; 几何 / 渲染
 session-views session-rectangles session-screen session-patch sync-layout!
 session-focused-did
 ;; 文档 / 视图结构 + 读
 session-open-document session-add-document session-add-view
 session-document-ids session-view-ids-of session-document-name
 session-view-did session-view-point session-view-point-line
 session-view-point-column
 session-view-width session-view-height session-view-line-numbers? session-view-string
 session-view-id-list session-document-view-list
 ;; 保存句柄 / 脏
 session-document-string session-mark-saved session-dirty?
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
  (for/list ([p (in-list (session-views s))])
    (define vid (placed-vid p))
    (rectangle vid (placed-x p) (placed-y p) (placed-w p) (placed-h p) 0)))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

;; 本帧几何落到各 view 的视口尺寸（ensure / 上下移动用；幂等）。
(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 渲染 ----------

(define (session-screen s)
  (editor-render-layout (session-ed s) (session-rectangles s)
                        (session-focus-vid s) (session-width s) (session-height s)))

(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)))

;;; ---------- 文档 / 视图结构 ----------

(define (session-open-document s doc [keys (kbd)] #:name [name "*scratch*"])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (values (struct-copy session s
            [ed ed*]
            [doc-keymaps (hash-set (session-doc-keymaps s) did keys)])
          did))

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
(define (session-view-width s vid) (editor-view-width (session-ed s) vid))
(define (session-view-height s vid) (editor-view-height (session-ed s) vid))
(define (session-view-line-numbers? s vid) (editor-view-line-numbers? (session-ed s) vid))
(define (session-view-string s vid) (editor-view-string (session-ed s) vid))
(define (session-view-id-list s) (editor-view-id-list (session-ed s)))
(define (session-document-view-list s did) (editor-document-view-list (session-ed s) did))
(define (session-document-string s did) (editor-document-string (session-ed s) did))

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
