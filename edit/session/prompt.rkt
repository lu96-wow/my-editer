#lang racket

;;; edit/session/prompt.rkt —— 输入行（底部，与 status / log 互斥）
;;;
;;; 打开 / 提交 / 取消。提交先关输入行再跑回调，所以回调里出错时 prompt 已 #f（会弹 log）。

(require "value.rkt"
         "core.rkt"
         "bottom.rkt"
         "focus.rkt"
         "../core/focus.rkt")

(provide session-prompt-open session-prompt-submit session-prompt-cancel)

(define (prompt-document label)
  (panel-doc (list (list label #f))))

(define (session-prompt-open s vid label on-submit)
  (define s1 (session-ed-assign! s vid (prompt-document label)))
  (define s2 (session-ed-set-point! s1 vid 0 (string-length label)))
  (define s3 (session-bottom-select s2 'input))
  (define s4 (session-set-focus s3 (focus-push (session-focus s3) vid)))
  (struct-copy session s4 [prompt (prompt vid label on-submit)]))

(define (session-prompt-close s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define s1 (session-bottom-select s 'status))
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
