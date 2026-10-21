#lang racket

;;; edit-tui-rebuild/filetree/sync.rkt —— 文件树同步
;;;
;;; 同步模式（测试 / 无 job runtime）：
;;;   projection-key 变 -> 主线程 dir-entries -> rows -> 写 view
;;;
;;; 异步模式（boot/sync 默认）：
;;;   projection-key 变 -> 提交 filetree-scan job，旧 rows 继续显示
;;;   worker 返回 rows -> handle-filetree-job-result 按 key 校验
;;;   下一帧 sync 把接受的 rows 写进 view
;;;
;;; 一个 filetree job 在飞时不重复提交；过期结果只清 pending，下一帧再请求。

(require racket/match
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/event.rkt"
         "slice.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt")

(provide sync-filetree!
         handle-filetree-job-result
         filetree-services)

(struct filetree-scan-result (projection rows) #:transparent)

(define (opened-path-set state)
  (for/fold ([h (hash)]) ([r (in-list (resource-list (app-state-resources state)))])
    (define p (resource-path (app-state-resources state) (resource-id r)))
    (if p
        (hash-set h (resource-normalize-path p) #t)
        h)))

;;; 行投影的输入：root + 展开集合 + 已打开集合。
(define (filetree-projection-key root expanded opened show-hidden?)
  (list root
        (sort (hash-keys expanded) string<?)
        (sort (hash-keys opened) string<?)
        show-hidden?))

;;; sync 的完整输入：view + rows 投影输入 + 期望光标。
(define (filetree-sync-input vid projection-key line col)
  (list vid projection-key line col))

(define (current-opened state f)
  (define store (app-state-resources state))
  (define opened-revision (resource-opened-revision store))
  (if (equal? opened-revision (filetree-opened-revision f))
      (filetree-opened f)
      (opened-path-set state)))

(define (current-projection-key state f)
  (define store (app-state-resources state))
  (filetree-projection-key (resource-root store)
                           (filetree-expanded f)
                           (current-opened state f)
                           (filetree-show-hidden? f)))

(define (write-filetree-view! state engine f projection rows line col)
  (define vid (filetree-view f))
  (engine-set-view-lines! engine vid
                          (map filetree-line-text rows)
                          (map filetree-line-face rows)
                          line
                          #:column col)
  ;; 写回镜像（engine 会 clamp/scroll）；sync-key 用实际光标。
  (define actual-line (or (engine-view-point-line engine vid) line))
  (define actual-col (or (engine-view-point-column engine vid) col))
  (define actual-key (filetree-sync-input vid projection actual-line actual-col))
  (filetree-put state
                (filetree-set-sync f projection rows actual-key actual-line)))

(define (sync-filetree! state engine #:async? [async? #f])
  (define f (filetree-of state))
  (cond
    [(or (not f) (not (filetree-view f))) state]
    [else
     (define store (app-state-resources state))
     (define root (resource-root store))
     (define expanded (filetree-expanded f))
     (define opened (current-opened state f))
     (define opened-revision (resource-opened-revision store))
     (define f0
       (if (equal? opened-revision (filetree-opened-revision f))
           f
           (filetree-set-opened f opened opened-revision)))
     (define projection-key
       (filetree-projection-key root expanded opened
                                (filetree-show-hidden? f0)))
     (define vid (filetree-view f0))
     ;; 键盘移动（cursor-dirty? = #t）用 state 的 cursor；否则以 view 的光标为准。
     (define-values (line col)
       (if (filetree-cursor-dirty? f0)
           (values (filetree-cursor f0) 0)
           (values (or (engine-view-point-line engine vid) 0)
                   (or (engine-view-point-column engine vid) 0))))
     (define sync-input (filetree-sync-input vid projection-key line col))
     (cond
       [(equal? sync-input (filetree-sync-key f0))
        (if (eq? f0 f) state (filetree-put state f0))]

       [else
        (define cached? (equal? projection-key (filetree-projection f0)))
        (cond
          [cached?
           (write-filetree-view! state engine f0 projection-key
                                 (filetree-rows f0) line col)]

          [async?
           (if (filetree-pending-projection f0)
               (filetree-put state f0)
               (let-values ([(state* _job)
                             (app-state-submit-job
                              state 'filetree-scan
                              (list 'filetree-scan projection-key root expanded opened
                                    (filetree-show-hidden? f0)
                                    (filetree-hidden-entry? f0))
                              (list vid projection-key))])
                 (filetree-put state*
                               (filetree-set-scan-pending f0 projection-key))))]

          [else
           (define rows
             (filetree-lines root expanded opened dir-entries
                             #:show-hidden? (filetree-show-hidden? f0)
                             #:hidden-entry? (or (filetree-hidden-entry? f0)
                                                 default-hidden-entry?)))
           (write-filetree-view! state engine f0 projection-key rows line col)])])]))

;;; ════════════════ 后台 scan service / result ════════════════

(define (filetree-scan-service payload)
  (match-define (list 'filetree-scan projection root expanded opened
                      show-hidden? hidden-entry?)
    payload)
  (define rows
    (filetree-lines root expanded opened dir-entries
                    #:show-hidden? show-hidden?
                    #:hidden-entry? (or hidden-entry? default-hidden-entry?)))
  (filetree-scan-result projection rows))

(define filetree-services
  (list (service 'filetree-scan filetree-scan-service)))

;; run-loop / demo 在 job-finish 之后调用。
(define (handle-filetree-job-result state ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'filetree-scan)) state]
    [else
     (define f (filetree-of state))
     (cond
       [(not f) state]
       [else
        (define result (job-result-event-result ev))
        (define pending (filetree-pending-projection f))
        (cond
          [(not (filetree-scan-result? result))
           ;; worker 失败：清掉当前 pending，下一帧可以重试。
           (if pending (filetree-put state (filetree-clear-scan-pending f)) state)]
          [else
           (define result-key (filetree-scan-result-projection result))
           (define current-key (current-projection-key state f))
           (cond
             [(equal? result-key current-key)
              (filetree-put state
                            (filetree-set-scan-result f result-key
                                                      (filetree-scan-result-rows result)))]
             [(equal? result-key pending)
              (filetree-put state (filetree-clear-scan-pending f))]
             [else state])])])]))
