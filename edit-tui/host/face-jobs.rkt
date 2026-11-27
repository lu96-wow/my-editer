#lang racket

;;; edit-tui/host/face-jobs.rkt —— 属性写入 worker
;;;
;;; 纯属性（face）不进入 State，也不需要 job-result 回主线程：
;;;   · 主线程提交 thunk，thunk 捕获稳定的 face-target / document 版本；
;;;   · 单个 worker 串行执行，保证同一时刻只有一个属性 writer；
;;;   · 同一 key（这里用 buffer 对象）只保留最新任务，避免连续编辑排队；
;;;   · thunk 直接写 core face 端口，完成后只发一个「重绘」信号。
;;;
;;; 冲突插件（语法 / 同词 / 括号）必须在同一个 thunk 里按固定顺序合成最终
;;; face track，不能拆成多个 writer 并发写同一 buffer。

(require racket/async-channel)

(provide (struct-out face-runtime)
         start-face-runtime
         stop-face-runtime
         face-runtime-paint-channel
         face-runtime-consume-paint!
         face-runtime-submit)

(struct face-runtime
  (request-channel
   paint-channel
   worker
   pending       ; hasheq: key -> thunk（最新任务）
   queued        ; hasheq: key -> #t（request-channel 里是否已有该 key）
   paint-pending? ; box：已发过重绘信号但主线程还没消费
   lock)         ; 保护 pending / queued / paint-pending?
  #:mutable
  #:transparent)

(define (signal-paint! rt)
  (define send?
    (let ()
      (semaphore-wait (face-runtime-lock rt))
      (define pending? (unbox (face-runtime-paint-pending? rt)))
      (unless pending?
        (set-box! (face-runtime-paint-pending? rt) #t))
      (semaphore-post (face-runtime-lock rt))
      (not pending?)))
  (when send?
    (async-channel-put (face-runtime-paint-channel rt) #t)))

;; 主线程在 source proc 里调用：清掉 pending 标记，然后渲染一帧。
(define (face-runtime-consume-paint! rt)
  (semaphore-wait (face-runtime-lock rt))
  (set-box! (face-runtime-paint-pending? rt) #f)
  (semaphore-post (face-runtime-lock rt))
  (void))

(define (take-latest! rt key)
  (semaphore-wait (face-runtime-lock rt))
  (define thunk (hash-ref (face-runtime-pending rt) key #f))
  (hash-remove! (face-runtime-pending rt) key)
  (hash-remove! (face-runtime-queued rt) key)
  (semaphore-post (face-runtime-lock rt))
  thunk)

(define (worker-loop rt)
  (let loop ()
    (define key (async-channel-get (face-runtime-request-channel rt)))
    (define thunk (take-latest! rt key))
    (when thunk
      (with-handlers ([exn:fail?
                       (λ (e)
                         (eprintf "face worker: ~a\n" (exn-message e)))])
        (thunk))
      (signal-paint! rt))
    (loop)))

;; key 用 eq? 比较；同一个 key 只保留最新 thunk。
(define (face-runtime-submit rt)
  (λ (key thunk)
    (define send?
      (let ()
        (semaphore-wait (face-runtime-lock rt))
        (hash-set! (face-runtime-pending rt) key thunk)
        (define already? (hash-has-key? (face-runtime-queued rt) key))
        (unless already?
          (hash-set! (face-runtime-queued rt) key #t))
        (semaphore-post (face-runtime-lock rt))
        (not already?)))
    (when send?
      (async-channel-put (face-runtime-request-channel rt) key))
    (void)))

(define (start-face-runtime
         #:paint-channel [paint-channel (make-async-channel)])
  (define rt (face-runtime (make-async-channel)
                           paint-channel
                           #f
                           (make-hasheq)
                           (make-hasheq)
                           (box #f)
                           (make-semaphore 1)))
  (set-face-runtime-worker!
   rt
   (thread (λ () (worker-loop rt))))
  rt)

(define (stop-face-runtime rt)
  (when rt
    (kill-thread (face-runtime-worker rt)))
  (void))
