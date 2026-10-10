#lang racket

;;; edit-rebuild/core/session/prompt.rkt —— 输入行机制（通用，与具体面板无关）
;;;
;;; 局部问题：打开 / 提交 / 取消一条输入行。输入行的**面板**由插件提供；这里只维护
;;; 输入态（input-state.prompt）：把只读前缀 + 可写正文装进给定 vid、聚焦、提交取文本。
;;;
;;; 打开入口是命令 cmd-prompt-open（label on-submit）；输入行插件负责先把自己的
;;; 面板显示出来，再调 session-prompt-open。

(require "session.rkt"
         "adapter.rkt"
         "focus.rkt"
         "../focus.rkt")

(provide (struct-out prompt)
         session-prompt-open session-prompt-submit session-prompt-cancel)

(struct prompt (vid label on-submit) #:transparent)
;; vid       : 输入行视图
;; label     : 只读前缀
;; on-submit : session string -> session

(define (session-prompt-open s vid label on-submit)
  (define s1 (session-ed-assign! s vid (input-document label)))
  (define s2 (session-ed-set-point! s1 vid 0 (string-length label)))
  (define s3 (session-set-focus s2 (focus-push (session-focus s2) vid)))
  (session-set-prompt s3 (prompt vid label on-submit)))

(define (session-prompt-close s)
  (cond
    [(not (session-prompt s)) s]
    [else (session-set-prompt (session-set-focus s (focus-restore (session-focus s))) #f)]))

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
