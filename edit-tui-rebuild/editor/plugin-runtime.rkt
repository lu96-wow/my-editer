#lang racket

;;; edit-tui-rebuild/editor/plugin-runtime.rkt —— contribution registry 执行器
;;;
;;; 只由 host-api 导出；插件 API 不导出这些函数。

(require "context.rkt"
         "contributions.rkt"
         "job.rkt")

(provide run-plugin-syncs
         run-plugin-overlays
         run-plugin-timer-handlers
         run-plugin-job-handlers
         editor-services)

(define (run-plugin-syncs ed state)
  (for/fold ([s state])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/frame-sync))])
    ((contribution-fn c) ed s)))

(define (run-plugin-overlays ed state)
  (append*
   (for/list ([c (in-list (registry-contributions
                           (editor-contributions ed) point/frame-overlay))])
     ((contribution-fn c) ed state))))

(define (run-plugin-timer-handlers ed state ev)
  (for/fold ([s state])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/timer))])
    ((contribution-fn c) ed s ev)))

(define (run-plugin-job-handlers ed state ev)
  (define kind (job-result-event-kind ev))
  (for/fold ([s state])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/job-result kind))])
    ((contribution-fn c) ed s ev)))

(define (editor-services ed)
  (registry-services (editor-contributions ed)))
