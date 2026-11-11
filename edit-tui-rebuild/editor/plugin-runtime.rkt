#lang racket

;;; edit-tui-rebuild/editor/plugin-runtime.rkt —— contribution registry 执行器
;;;
;;; 只由 host-api 导出；插件 API 不导出这些函数。
;;;
;;; 所有插件回调都只拿到自己的 plugin-state，并返回自己的 plugin-state。
;;; 写回统一在这里完成：owner 来自 contribution，插件没有办法指定别的 owner。
;;;
;;; 回调约定：
;;;   sync       (ed state ps)       -> (values state' ps')
;;;   overlay    (ed state ps)       -> (listof editor-overlay)
;;;   timer      (ed state ps ev)    -> (values state' ps' actions)
;;;   job-result (ed state ps ev)    -> (values state' ps' actions)
;;;
;;; state' 可以带 job ledger / flash 等 host 可见状态；plugin-states 的最后
;;; 值以 ps' 为准，由本模块按 contribution owner 写回。

(require "context.rkt"
         "contributions.rkt"
         "state.rkt"
         "job.rkt")

(provide run-plugin-syncs
         run-plugin-overlays
         run-plugin-timer-handlers
         run-plugin-job-handlers
         editor-services)

(define (plugin-state-of state owner)
  (editor-state-plugin-state state owner))

(define (write-plugin-state state owner ps)
  (editor-state-set-plugin-state state owner ps))

(define (run-plugin-syncs ed state)
  (for/fold ([s state])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/frame-sync))])
    (define owner (contribution-owner c))
    (define-values (s* ps*)
      ((contribution-fn c) ed s (plugin-state-of s owner)))
    (write-plugin-state s* owner ps*)))

(define (run-plugin-overlays ed state)
  (append*
   (for/list ([c (in-list (registry-contributions
                           (editor-contributions ed) point/frame-overlay))])
     ((contribution-fn c) ed state (plugin-state-of state (contribution-owner c))))))

(define (run-plugin-timer-handlers ed state ev)
  (for/fold ([s state] [actions '()])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/timer))])
    (define owner (contribution-owner c))
    (define-values (s* ps* actions*)
      ((contribution-fn c) ed s (plugin-state-of s owner) ev))
    (values (write-plugin-state s* owner ps*)
            (append actions actions*))))

(define (run-plugin-job-handlers ed state ev)
  (define kind (job-result-event-kind ev))
  (for/fold ([s state] [actions '()])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/job-result kind))])
    (define owner (contribution-owner c))
    (define-values (s* ps* actions*)
      ((contribution-fn c) ed s (plugin-state-of s owner) ev))
    (values (write-plugin-state s* owner ps*)
            (append actions actions*))))

(define (editor-services ed)
  (registry-services (editor-contributions ed)))
