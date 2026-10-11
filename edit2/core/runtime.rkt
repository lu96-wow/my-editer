#lang racket

;;; edit2/runtime.rkt —— 事件循环 + worker 池 + 后端协议（唯一可变处）
;;;
;;;   run : Backend (listof route) State -> State
;;;
;;; 主循环：diff 启停 worker → 刷新面板 → layout → render → 画 →
;;; 等事件 → step → perform!（一次性 IO）。
;;; 可变只有：本文件的 running/old、终端、缓存。State 只经 step 产生新值。

(provide (struct-out backend) run default-perform!)

(require racket/async-channel
         "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "layout.rkt" "render.rkt" "step.rkt" "adapter.rkt")

;;; ---------- 后端协议 ----------

;; draw! 收到 (listof piece)（新帧相对上一帧的增量）。
(struct backend (size        ; -> (cons w h)
                 read-event  ; -> Event（阻塞）
                 draw!       ; (listof piece) -> void
                 close)      ; -> void
  #:transparent)

;;; ---------- worker 池 ----------

(define (start-job ch j worker-of)
  (define w (worker-of (job-kind j)))
  (and w
       (thread
        (lambda ()
          (define res
            (with-handlers ([exn:fail? (lambda (e) (string-append "job error: " (exn-message e)))])
              (w (job-input j))))
          (async-channel-put ch (job-event (job-id j) (job-key j) res))))))

(define (reconcile ch st running worker-of jobs-fn)
  (define want (for/hash ([j (in-list (jobs-fn st))]) (values (job-id j) j)))
  (for ([(id rt) (in-hash running)]
        #:unless (and (hash-has-key? want id)
                      (equal? (car rt) (job-key (hash-ref want id)))))
    (kill-thread (cdr rt)))
  (define kept
    (for/hash ([(id rt) (in-hash running)]
               #:when (and (hash-has-key? want id)
                           (equal? (car rt) (job-key (hash-ref want id)))))
      (values id rt)))
  (for/fold ([r kept]) ([j (in-list (jobs-fn st))] #:unless (hash-has-key? kept (job-id j)))
    (define t (start-job ch j worker-of))
    (if t (hash-set r (job-id j) (cons (job-key j) t)) r)))

;;; ---------- 一次性 IO ----------

(define (default-perform! e)
  (cond
    [(log-effect? e) (eprintf "~a\n" (log-effect-msg e))]
    [(save-file? e)
     (with-handlers ([exn:fail? (lambda (ex) (eprintf "save 失败: ~a\n" (exn-message ex)))])
       (call-with-output-file (save-file-path e)
         #:exists 'truncate/replace
         (lambda (out) (display (save-file-text e) out))))]
    [(open-file? e)  (eprintf "[open-file] ~a\n" (open-file-path e))]
    [else (void)]))

;;; ---------- 主循环 ----------

(define (run b routes initial
             #:jobs [jobs-fn jobs]
             #:worker [worker-of (lambda (kind) #f)]
             #:perform [perform! default-perform!])
  (define ch (make-async-channel))
  (define cust (make-custodian))
  (parameterize ([current-custodian cust])
    (thread (lambda () (let loop ()
                         (define ev ((backend-read-event b)))
                         (async-channel-put ch ev)
                         (loop)))))
  (define result
    (let loop ([st initial] [running (hash)] [old #f] [old-size #f])
      (define running* (reconcile ch st running worker-of jobs-fn))
      (define size ((backend-size b)))
      (define st1 (refresh-panels! st))          ; 刷面板（树缓存/内容），拿回更新后的状态
      (define placements (layout (state-layout st1) size))
      (define-values (screen rends sels)
        (render st1 placements size (and (equal? size old-size) old)))
      ((backend-draw! b) (append rends sels))
      (define ev (async-channel-get ch))
      (define-values (st* effs) (step routes (ctx size placements) st1 ev))
      (for ([e (in-list effs)]) (perform! e))
      (if (for/or ([e (in-list effs)]) (quit-effect? e))
          (begin ((backend-close b)) st*)
          (loop st* running* screen size))))
  (custodian-shutdown-all cust)
  result)

