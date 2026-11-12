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
;;;   command    (ed state ps)       -> (values state' ps' actions)
;;;
;;; command 不是在这里执行：这里只把 registry 里的 command-binding 汇总成
;;; 纯 command-table。leaf 的值是 ordered (owner . command) 列表，host 再逐个
;;; 跑 guard；guard 不成立时可以落到同一 key 的下一条 / 下一张 host 表。
;;;
;;; state' 可以带 job ledger / flash 等 host 可见状态；plugin-states 的最后
;;; 值以 ps' 为准，由本模块按 contribution owner 写回。

(require "../core/command/api.rkt"
         "context.rkt"
         "contributions.rkt"
         "state.rkt"
         "job.rkt"
         "plugin.rkt")

(provide run-plugin-syncs
         run-plugin-overlays
         run-plugin-timer-handlers
         run-plugin-job-handlers
         editor-services
         editor-command-table
         active-key-owner)

(define (plugin-state-of state owner)
  (state-plugin-state state owner))

(define (write-plugin-state state owner ps)
  (state-set-plugin-state state owner ps))

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

;; completion 等 overlay 声明当前键盘 owner；返回第一个非 #f 的 scope。
(define (active-key-owner ed state)
  (for/or ([c (in-list (registry-contributions
                        (editor-contributions ed) point/key-owner))])
    (define owner (contribution-owner c))
    ((contribution-fn c) ed state (plugin-state-of state owner))))

;;; ════════════════ command registry -> command-table ════════════════

;; bindings : (listof (list keys owner value))，按 registry 顺序。
;; 同一个 key 的多条命令保持顺序；leaf 存 ((owner . value) ...)。
(define (command-bindings->table bindings)
  (define grouped
    (for/fold ([h (hash)]) ([b (in-list bindings)])
      (define keys (car b))
      (define owner (cadr b))
      (define value (caddr b))
      (hash-update h keys
                   (λ (old) (append old (list (cons owner value))))
                   '())))
  (for/fold ([t command-table-empty]) ([(keys entries) (in-hash grouped)])
    (command-table-add t keys entries)))

(define (editor-command-bindings ed scope)
  (for/list ([c (in-list (registry-contributions
                          (editor-contributions ed) point/command scope))])
    (define b (contribution-fn c))
    (list (command-binding-keys b)
          (contribution-owner c)
          (command-binding-value b))))

(define (editor-command-table ed [scope 'global])
  (command-bindings->table (editor-command-bindings ed scope)))
