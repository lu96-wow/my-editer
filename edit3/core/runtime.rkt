#lang racket

;;; edit3/runtime.rkt —— 事件循环 + 后端协议（唯一可变处）
;;;
;;; 每帧：layout → render → draw → read-event → step → perform。
;;; 本步只有退出 effect；不做 jobs。

(provide (struct-out backend) run default-perform!)

(require "state.rkt" "event.rkt" "effect.rkt" "layout.rkt" "render.rkt" "step.rkt" "panels.rkt" "fs.rkt")

(struct backend (size read-event draw! close) #:transparent)

(define (default-perform! e)
  (cond [(log-effect? e) (eprintf "~a\n" (log-effect-msg e))]
        [(save-file? e) (fs-write-file (save-file-path e) (save-file-text e))]
        [else (void)]))

(define (run b initial #:perform [perform! default-perform!])
  (let loop ([st initial] [old #f] [old-size #f])
    (define st1 (refresh-panels! st))            ; 面板内容 = State 的纯投影
    (define size ((backend-size b)))
    (define g (layout (state-tiling st1) (state-floats st1) size))
    (define-values (screen rends sels)
      (render st1 g (and (equal? size old-size) old)))
    ((backend-draw! b) (append rends sels))
    (define ev ((backend-read-event b)))
    (define-values (st* effs) (step st1 size ev))
    (for ([e (in-list effs)]) (perform! e))
    (if (for/or ([e (in-list effs)]) (quit-effect? e))
        (begin ((backend-close b)) st*)
        (loop st* screen size))))
