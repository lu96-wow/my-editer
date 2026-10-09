#lang racket

;;; edit/session/panel.rkt —— 状态窗口：枚举 / 互换 / 刷新
;;;
;;; 纯查询（session-panel / -panel-vid / -vid-keys / -dock-vid? / -add-panel / -add-handler）
;;; 在 value.rkt。这里只有需要内核 / 轮廓的机制。

(require "value.rkt"
         "core.rkt"
         "focus.rkt"
         "../core/focus.rkt"
         "../core/ids.rkt")

(provide session-panel-dids session-panel-swap
         session-refresh session-prepare-render)

;;; ---------- 状态窗口 ----------

(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (session-view-did s (panel-vid p))))

;; 同区域窗口互换：Tab。底部区（slot-bottom）由底部选择机制管，不参与 Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define (usable? p) (and p (not (eq? (panel-region p) slot-bottom))))
  (define region
    (cond [(and curp (usable? curp)) (panel-region curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (usable? p))
                  (panel-region p))]))
  (cond
    [(not region) s]
    [else
     (define members (for/list ([p (in-list (session-panels s))]
                               #:when (eq? region (panel-region p))) p))
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

;;; ---------- 渲染前准备 ----------

;; 刷新面板 + 应用 document 插件（懒：只对句柄变了的文档重写 face）。
;; 后端每次画帧前调一次，返回值带回写回缓存。
(define (session-prepare-render s)
  (session-doc-plugins-apply (session-refresh s)))
