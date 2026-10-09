#lang racket

;;; edit/command/session-window.rkt —— 状态窗口（机制）+ 输入行 + 命令处理链 + refresh
;;;
;;; 纯查询（session-panel / -panel-vid / -vid-keys / -dock-vid? / -add-panel）在 session-value。
;;; 这里只有需要内核 / 轮廓的机制：panel-dids、同位置互换、刷新、输入行、handler 链。

(require "session-value.rkt"
         "session-core.rkt"
         "session-focus.rkt"
         "../../core/text/document.rkt"
         "../core/focus.rkt")

(provide
 session-panel-dids session-panel-swap
 session-add-handler
 session-refresh
 session-prompt-open session-prompt-submit session-prompt-cancel)

;;; ---------- 状态窗口 ----------

(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (session-view-did s (panel-vid p))))

;; 同组（同位置）窗口互换：Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define group
    (cond [(and curp (panel-group curp)) (panel-group curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (panel-group p))
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

;;; ---------- 命令处理链 ----------

(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))

;;; ---------- 刷新状态窗口 ----------

(define (session-refresh s)
  (for ([p (in-list (session-panels s))])
    (define f (panel-refresh p))
    (when f
      (define doc (f s))
      (when doc (session-ed-assign! s (panel-vid p) doc))))
  s)

;;; ---------- 输入行 ----------

(define (prompt-document label)
  (define doc (document-open label))
  (when (positive? (string-length label))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length label) #t))))
  doc)

(define (session-prompt-open s vid label on-submit)
  (define s1 (session-ed-assign! s vid (prompt-document label)))
  (define s2 (session-ed-set-point! s1 vid 0 (string-length label)))
  (define s3 (session-set-visible s2 vid #t))
  (define s4 (session-set-focus s3 (focus-push (session-focus s3) vid)))
  (struct-copy session s4 [prompt (prompt vid label on-submit)]))

(define (session-prompt-close s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define s1 (session-set-visible s (prompt-vid p) #f))
     (define s2 (session-set-focus s1 (focus-restore (session-focus s1))))
     (struct-copy session s2 [prompt #f])]))

;; Enter：取 label 之后的文本 → 关输入行 → 回调。
(define (session-prompt-submit s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define full (session-view-string s (prompt-vid p)))
     (define label (prompt-label p))
     (define text (substring full (min (string-length label) (string-length full))
                             (string-length full)))
     ((prompt-on-submit p) (session-prompt-close s) text)]))

(define (session-prompt-cancel s) (session-prompt-close s))
