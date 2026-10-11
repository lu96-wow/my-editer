#lang racket

;;; edit3/runtime.rkt —— 事件循环 + 后端协议 + worker 池（唯一可变处）
;;;
;;; 每帧：layout → render → draw → 派发 jobs → sync 事件 → step → perform。
;;; 输入线程把 backend 事件塞进事件通道；worker 线程把 job 结果以 job-event 塞进同一通道，
;;; 于是「键盘 / 鼠标 / 并发结果」走同一条事件流（Event ADT 的意义）。
;;; 只有本模块持有可变状态：事件通道、已派发 id 集合、worker 线程。

(provide (struct-out backend) run default-perform!)

(require "state.rkt" "event.rkt" "effect.rkt" "layout.rkt" "render.rkt" "step.rkt"
         "job.rkt" "panels.rkt" "fs.rkt" "hook.rkt")

(struct backend (size read-event draw! close) #:transparent)

(define (default-perform! e)
  (cond [(log-effect? e) (eprintf "~a\n" (log-effect-msg e))]
        [(save-file? e) (fs-write-file (save-file-path e) (save-file-text e))]
        [else (void)]))

;; 派发一个 job 到请求通道；worker 跑完把 (job-event ...) 推进事件通道。
(define (start-workers! req-ch ev-ch registry n)
  (for ([_ (in-range (max 1 n))])
    (thread
     (lambda ()
       (let loop ()
         (define j (channel-get req-ch))
         (define res
           (with-handlers ([exn:fail? (lambda (e) (list 'error (exn-message e)))])
             (run-service registry j)))
         (channel-put ev-ch (job-event (job-id j) (job-kind j) res (job-tag j)))
         (loop))))))

;; 输入线程：阻塞读 backend，转手塞进事件通道（与 job 结果合流）。
(define (start-input! b ev-ch)
  (thread (lambda () (let loop () (channel-put ev-ch ((backend-read-event b))) (loop)))))

(define (run b initial
             #:perform [perform! default-perform!]
             #:workers [workers 2])
  (define ev-ch (make-channel))
  (define req-ch (make-channel))
  (define registry (feature-ref initial 'services (make-service-registry)))
  (define input-thread (start-input! b ev-ch))
  (start-workers! req-ch ev-ch registry workers)
  (define dispatched (box (hash)))                    ; id -> #t（已派发，避免重复）
  (define (dispatch-new! st)
    (for ([j (in-list (jobs st))] #:unless (hash-has-key? (unbox dispatched) (job-id j)))
      (set-box! dispatched (hash-set (unbox dispatched) (job-id j) #t))
      (channel-put req-ch j)))
  (let loop ([st initial] [old #f] [old-size #f])
    (define size ((backend-size b)))
    (define st1 (emit (refresh-panels! st) 'before-render (list size)))   ; 面板内容 = State 的纯投影
    (define g (layout (state-tiling st1) (state-floats st1) size))
    (define-values (screen rends sels)
      (render st1 g (and (equal? size old-size) old)))
    ((backend-draw! b) (append rends sels))
    (dispatch-new! st1)
    (define ev (channel-get ev-ch))                  ; 阻塞：键盘 / 鼠标 / 并发结果
    (when (job-event? ev)
      (set-box! dispatched (hash-remove (unbox dispatched) (job-event-id ev))))
    (define-values (st* effs) (step st1 size ev))
    (for ([e (in-list effs)]) (perform! e))
    (if (for/or ([e (in-list effs)]) (quit-effect? e))
        (begin (kill-thread input-thread) ((backend-close b)) st*)
        (loop st* screen size))))
