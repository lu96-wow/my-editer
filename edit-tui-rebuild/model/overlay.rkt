#lang racket

;;; model/overlay.rkt —— 浮层（弹窗）状态（纯数据）
;;; layer  : model
;;; effect : 无（纯数据 + 纯更新）
;;;
;;; 浮层存在 workspace.overlays 里，投影层每帧按“锚点 view 的光标”算屏幕矩形。
;;;
;;;   (struct popup (id view lines selected))
;;;     id       : symbol        哪个插件 / 哪种弹窗（资源列表面板也用它区分）
;;;     view     : view-id       锚在哪个 view 的光标处（跟着光标走）
;;;     lines    : (listof string)  每行文本（弹窗自己不关心语义）
;;;     selected : natural | #f  选中行（#f = 纯展示，不可选）
;;;
;;; 约定：
;;;   · 浮层**不抢焦点**：焦点仍在编辑器，弹窗只是画在上面；
;;;   · 交互键由“临时模态”（input.modes）提供，弹窗本身不含键位；
;;;   · 没有选中行的浮层（selected = #f）只用来展示（例如提示 / 预览）。

(provide (struct-out popup)
         make-popup
         popup-show popup-hide popup-get popup-by-view
         popup-move popup-selected
         popup-line
         ;; state 级便捷封装
         state-popup-show state-popup-hide state-popup-get state-popup-move state-popup-lines)

(require "workspace.rkt"
         "state.rkt")

(struct popup (id view lines selected) #:transparent)

(define (make-popup id view lines [selected #f])
  (unless (symbol? id) (error 'make-popup "id 要是 symbol：~a" id))
  (for ([l (in-list lines)])
    (unless (string? l) (error 'make-popup "lines 里要 string：~a" l)))
  (popup id view lines selected))

;;; ---------- workspace 级 ----------

(define (popup-get w id)
  (for/first ([p (in-list (workspace-overlays w))] #:when (eq? (popup-id p) id)) p))

(define (popup-show w id view lines [selected #f])
  (define p* (make-popup id view lines selected))
  (struct-copy workspace w
               [overlays (cons p* (for/list ([p (in-list (workspace-overlays w))]
                                             #:unless (eq? (popup-id p) id))
                                    p))]))

(define (popup-hide w id)
  (struct-copy workspace w
               [overlays (for/list ([p (in-list (workspace-overlays w))]
                                    #:unless (eq? (popup-id p) id))
                           p)]))

;; 锚在某个 view 上的浮层（弹窗跟着光标 = 这个 view 的）
(define (popup-by-view w view)
  (for/first ([p (in-list (workspace-overlays w))] #:when (equal? (popup-view p) view)) p))

;; 选中行上下移动（循环）；selected = #f 的浮层原样返回。
(define (popup-move w id delta)
  (define p (popup-get w id))
  (cond
    [(not p) w]
    [(not (popup-selected p)) w]
    [else
     (define n (length (popup-lines p)))
     (define i (modulo (+ (popup-selected p) delta) n))
     (struct-copy workspace w
                  [overlays (for/list ([q (in-list (workspace-overlays w))])
                              (if (eq? (popup-id q) id)
                                  (struct-copy popup q [selected i])
                                  q))])]))

(define (popup-line p i)
  (and (exact-nonnegative-integer? i) (< i (length (popup-lines p)))
       (list-ref (popup-lines p) i)))

;;; ---------- state 级 ----------

(define (state-popup-get s id) (popup-get (state-workspace s) id))

(define (state-popup-show s id view lines [selected #f])
  (state-workspace* s (λ (w) (popup-show w id view lines selected))))

(define (state-popup-hide s id)
  (state-workspace* s (λ (w) (popup-hide w id))))

(define (state-popup-move s id delta)
  (state-workspace* s (λ (w) (popup-move w id delta))))

(define (state-popup-lines s id)
  (define p (state-popup-get s id))
  (and p (popup-lines p)))
