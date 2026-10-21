#lang racket

;;; edit-tui/demo/completion-popup.rkt —— 补全弹窗几何 + 内容（纯）
;;;
;;; 约束：
;;;   · 弹窗必须在整个编辑区的包围盒内，而不是单个 editor panel；
;;;   · 不覆盖当前光标行；
;;;   · 宽度由候选最长文本 + 边框决定，并受编辑区宽度限制；
;;;   · 高度由候选数和光标上下可用空间决定；
;;;   · 选中只靠 face，不加 ">" 之类前缀。

(provide (struct-out popup-layout)
         popup-geometry
         completion-lines
         fit-line)

(require "../core/base/api.rkt"
         racket/string)

(struct popup-layout
  (rect          ; 外框
   inner-width   ; 内容宽
   inner-height) ; 可见内容行数
  #:transparent)

;; 文本裁到 inner-width，短行补空格，保证整行 face（选中底色）铺满。
(define (fit-line s width)
  (define w (max 0 width))
  (cond
    [(<= (string-length s) w)
     (string-append s (make-string (- w (string-length s)) #\space))]
    [else (substring s 0 w)]))

(define (completion-lines candidates inner-width)
  (for/list ([x (in-list candidates)])
    (fit-line x inner-width)))

;; area         : 整个终端 rect
;; editor-area  : 所有可见 editor panel 的包围盒 rect
;; cursor-x/y   : 光标屏幕坐标
;; count        : 候选数
;; max-width    : 候选最长字符串长度
;; → popup-layout | #f
(define (popup-geometry area editor-area cursor-x cursor-y count max-width)
  (define aw (rect-w area))
  (define ah (rect-h area))
  (define ew (rect-w editor-area))
  (define eh (rect-h editor-area))
  (cond
    [(or (<= aw 0) (<= ah 0) (<= ew 3) (<= eh 2)
         (<= count 0) (<= max-width 0))
     #f]
    [else
     ;; 内容宽按最长候选算；外框 = 内容 + 左右边框。
     (define outer-width (max 4 (min (+ max-width 2) ew)))
     (define inner-width (- outer-width 2))

     ;; 光标行夹到编辑区内。
     (define cy (max (rect-y editor-area)
                     (min cursor-y (sub1 (rect-bottom editor-area)))))
     (define below-top (+ cy 1))
     (define below-space (max 0 (- (rect-bottom editor-area) below-top)))
     (define above-space (max 0 (- cy (rect-y editor-area))))
     (define below-cap (max 0 (- below-space 2))) ; 上下边框
     (define above-cap (max 0 (- above-space 2)))

     (define desired count)
     (define use-below?
       (cond
         [(>= below-cap desired) #t]
         [(>= above-cap desired) #f]
         [else (>= below-cap above-cap)]))
     (define cap (if use-below? below-cap above-cap))
     (define inner-height (min desired cap))
     (cond
       [(<= inner-height 0) #f]
       [else
        (define outer-height (+ inner-height 2))
        (define x* (+ cursor-x 0))
        (define x (max (rect-x editor-area)
                       (min x* (- (rect-right editor-area) outer-width))))
        (define y (if use-below?
                      below-top
                      (- cy outer-height)))
        (popup-layout (rect x y outer-width outer-height)
                      inner-width
                      inner-height)])]))
