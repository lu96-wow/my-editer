#lang racket

;;; edit/session/panel.rkt —— 状态窗口：枚举 / 互换 / 刷新
;;;
;;; 纯查询（session-panel / -panel-vid / -vid-keys / -dock-vid? / -add-panel / -add-handler）
;;; 在 value.rkt。这里只有需要内核 / 轮廓的机制。

(require "value.rkt"
         "core.rkt"
         "focus.rkt"
         "../core/focus.rkt")

(provide session-panel-dids session-panel-swap
         session-refresh)

;;; ---------- 状态窗口 ----------

(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (session-view-did s (panel-vid p))))

;; 同组（同位置）窗口互换：Tab。底部组（'bottom）由底部选择机制管，不参与 Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define (usable? g) (and g (not (eq? g 'bottom))))
  (define group
    (cond [(and curp (usable? (panel-group curp))) (panel-group curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (usable? (panel-group p)))
                  (panel-group p))]))
  (cond
    [(not group) s]
    [else
     (define members (for/list ([p (in-list (session-panels s))]
                               #:when (eq? group (panel-group p))) p))
     (define idx (for/first ([p (in-list members)] [i (in-naturals)]
                             #:when (eqv? (panel-vid p) cur)) i))
     (define chosen (list-ref members (if idx (modulo (add1 idx) (length members)) 0)))
     (define cvid (panel-vid chosen))
     (define s1 (for/fold ([s s]) ([p (in-list members)])
                  (session-set-visible s (panel-vid p) (eqv? (panel-vid p) cvid))))
     (session-set-focus s1 (focus-set (session-focus s1) cvid))]))

;;; ---------- 刷新状态窗口 ----------

(define (session-refresh s)
  (for ([p (in-list (session-panels s))])
    (define f (panel-refresh p))
    (when f
      (define doc (f s))
      (when doc (session-ed-assign! s (panel-vid p) doc))))
  s)
