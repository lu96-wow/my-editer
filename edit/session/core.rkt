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
         "../../core/text/base/range.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt"
         (only-in "../../core/text/slot-dsl.rkt" define-document-slot)
         (only-in "../../core/text/slots.rkt" fork-ctx-changes fork-ctx-new-text fork-ctx-old-text)
         racket/string
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt"
         "../core/face.rkt"
         "../core/line-scan.rkt")

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
 session-overlay-dids
 session-view-did session-view-point session-view-point-line
 session-view-point-column session-view-point->screen session-view-cursor-screen
 session-view-width session-view-height session-view-line-numbers? session-view-string
 session-view-id-list session-document-view-list
 session-document-handle session-document-track
 ;; 保存句柄 / 脏
 session-document-string session-mark-saved session-dirty?
 ;; 文档槽（opaque 值，随版本 fork；插件状态等）
 define-document-slot session-doc-slot-ref session-doc-slot-set!
 ;; fork 上下文（插件增量状态用）
 fork-ctx-changes fork-ctx-old-text fork-ctx-new-text
 ;; 写回原语（face；插件层用）
 session-doc-face-lines!
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

;; 叠加层 → placed（各 deco 每帧产出）。
(define (session-deco-placed s)
  (append* (for/list ([d (in-list (session-decos s))]) ((deco-proc d) s))))

;; 所有已落位窗格：布局树 + 叠加层，按 deep 升序（大的在上）。
(define (session-panes s)
  (sort (append (session-views s) (session-deco-placed s)) < #:key placed-deep))

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

;; 某视图某点的**绝对屏幕坐标**（列, 行）。
;; 视图已落位但点不在视口 → 回退到视图左上角（保证有合法锚点）；视图未落位 → (#f #f)。
(define (session-view-point->screen s vid line col)
  (define pl (for/first ([p (in-list (session-views s))] #:when (eqv? vid (placed-vid p))) p))
  (cond
    [(not pl) (values #f #f)]
    [else
     (define-values (r c) (editor-view-point->screen-position (session-ed s) vid (point line col)))
     (if r
         (values (+ (placed-x pl) c) (+ (placed-y pl) r))
         (values (placed-x pl) (placed-y pl)))]))

;; 某视图光标的绝对屏幕坐标（列, 行）。补全弹窗锚点用。
(define (session-view-cursor-screen s vid)
  (session-view-point->screen s vid (session-view-point-line s vid)
                              (session-view-point-column s vid)))

(define (session-overlay-dids s)
  (for/list ([vid (in-list (session-overlays s))]) (session-view-did s vid)))
(define (session-view-width s vid) (editor-view-width (session-ed s) vid))
(define (session-view-height s vid) (editor-view-height (session-ed s) vid))
(define (session-view-line-numbers? s vid) (editor-view-line-numbers? (session-ed s) vid))
(define (session-view-string s vid) (editor-view-string (session-ed s) vid))
(define (session-view-id-list s) (editor-view-id-list (session-ed s)))
(define (session-document-view-list s did) (editor-document-view-list (session-ed s) did))
(define (session-document-string s did) (editor-document-string (session-ed s) did))
(define (session-document-handle s did) (editor-document-handle (session-ed s) did))

;;; ---------- 文档槽 ----------

;; 槽 = opaque 值，随版本 fork（见 core/text/slots.rkt）；按 did 寻址当前文档。
;; 声明（define-document-slot）由用方做，这里只提供读写。
(define (session-doc-slot-ref s did sl) (editor-document-slot-ref (session-ed s) did sl))
(define (session-doc-slot-set! s did sl v) (editor-document-slot-set! (session-ed s) did sl v) s)

;;; ---------- 文档文本轨（插件 open 用；不物化） ----------

(define (session-document-track s did)
  (document-text (session-document-handle s did)))

;;; ---------- 写回原语（按行增量） ----------

;; 只清脏行，再按插件顺序把各插件的层叠加到这些行上。
;; layers : (listof track)   各插件当前层（行 payload = (vectorof face) | #f）
;; dirty  : dirty             脏区
(define (session-doc-face-lines! s did layers dirty)
  (define doc (session-document-handle s did))
  (define text (document-text doc))
  (define n (track-length text))
  (define lines (dirty->lines dirty n))
  ;; 1) 清脏行：连续区间一条 fill 覆盖（半开 (lo,0)..(hi,0) = 覆盖 lo..hi-1 行）。
  (document-face-fill-batch
   doc
   (for/list ([run (in-list (contiguous-runs lines))])
     (define hi (sub1 (cdr run)))
     (list (car run) 0 hi (track-line-length text hi) #f)))
  ;; 2) 按目录顺序叠加各插件层（face-compose 保留分层）。
  (for ([layer (in-list layers)])
    (document-face-fill-batch*
     doc
     (append* (for/list ([ln (in-list lines)]
                         #:when (< ln (track-length layer)))
                (define vec (track-ref layer ln))
                (if vec
                    (for/list ([r (in-list (face-runs vec))])
                      (list ln (car r) ln (cadr r) (caddr r)))
                    '())))
     face-compose))
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
(define (session-ed-cut! s vid)
  (define-values (changes _ok?) (editor-view-cut! (session-ed s) vid))
  (values s changes))
(define (session-ed-paste! s vid)
  (define-values (changes _ok?) (editor-view-paste! (session-ed s) vid))
  (values s changes))

(define (session-ed-insert! s vid text)
  (define-values (changes _ok?) (editor-view-insert! (session-ed s) vid text))
  (values s changes))
(define (session-ed-delete! s vid)
  (define-values (changes _ok?) (editor-view-delete! (session-ed s) vid))
  (values s changes))
(define (session-ed-backspace! s vid)
  (define-values (changes _ok?) (editor-view-backspace! (session-ed s) vid))
  (values s changes))
(define (session-ed-undo! s vid) (editor-view-undo! (session-ed s) vid) (values s '()))
(define (session-ed-redo! s vid) (editor-view-redo! (session-ed s) vid) (values s '()))
