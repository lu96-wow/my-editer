#lang racket

;;; edit-tui/editor/plugin-runtime.rkt —— contribution registry 执行器
;;;
;;; 只由 host-api 导出；插件 API 不导出这些函数。
;;;
;;; 所有插件回调都只拿到自己的 plugin-state，并返回自己的 plugin-state。
;;; 写回统一在这里完成：owner 来自 contribution，插件没有办法指定别的 owner。
;;;
;;; 回调约定：
;;;   sync       (ed state ps)       -> (values state' ps')
;;;   overlay    (ed state ps)       -> (listof editor-overlay)
;;;              overlay 失败不会中断整帧：与其他回调一样 flash，并返回空列表。
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
         "area.rkt"
         "overlay.rkt"
         "error.rkt"
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

(define (plugin-failure-message owner callback e)
  (format "plugin ~a ~a failed: ~a" owner callback (exn-message e)))

(define (plugin-failure state owner callback e)
  (state-record-exception
   (state-with-flash state (plugin-failure-message owner callback e))
   'error 'plugin owner callback e))

(define (run-plugin-syncs ed state)
  (for/fold ([s state])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/frame-sync))])
    (define owner (contribution-owner c))
    (define ps (plugin-state-of s owner))
    (define-values (s* ps*)
      (with-handlers ([exn:fail?
                       (λ (e)
                         (values (plugin-failure s owner 'sync e) ps))])
        ((contribution-fn c) ed s ps)))
    (write-plugin-state s* owner ps*)))

(define (overlay-visible? state ov)
  (define anchor (editor-overlay-anchor-view-id ov))
  (or (not anchor)
      (editor-view-in-current-area? state anchor)))

(define (run-plugin-overlays ed state)
  ;; → (values state' (listof editor-overlay))
  ;; overlay 本身是纯的；这里只把失败信息变成 flash，不写 plugin-state。
  ;; anchor-view-id 不在当前编辑区时丢弃该 overlay。
  (for/fold ([s state] [overlays '()])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/frame-overlay))])
    (define owner (contribution-owner c))
    (define-values (s* ovs*)
      (with-handlers ([exn:fail?
                       (λ (e)
                         (values (plugin-failure s owner 'overlay e) '()))])
        (values s
                ((contribution-fn c) ed s (plugin-state-of s owner)))))
    (values s*
            (append overlays
                    (filter (λ (ov) (overlay-visible? s* ov)) ovs*)))))

(define (run-plugin-timer-handlers ed state ev)
  (for/fold ([s state] [actions '()])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/timer))])
    (define owner (contribution-owner c))
    (define ps (plugin-state-of s owner))
    (define-values (s* ps* actions*)
      (with-handlers ([exn:fail?
                       (λ (e)
                         (values (plugin-failure s owner 'timer e) ps '()))])
        ((contribution-fn c) ed s ps ev)))
    (values (write-plugin-state s* owner ps*)
            (append actions actions*))))

(define (run-plugin-job-handlers ed state ev)
  (define kind (job-result-event-kind ev))
  (for/fold ([s state] [actions '()])
            ([c (in-list (registry-contributions
                          (editor-contributions ed) point/job-result kind))])
    (define owner (contribution-owner c))
    (define ps (plugin-state-of s owner))
    (define-values (s* ps* actions*)
      (with-handlers ([exn:fail?
                       (λ (e)
                         (values (plugin-failure s owner 'job e) ps '()))])
        ((contribution-fn c) ed s ps ev)))
    (values (write-plugin-state s* owner ps*)
            (append actions actions*))))

(define (editor-services ed)
  (registry-services (editor-contributions ed)))

;; completion 等 overlay 声明当前键盘 owner；返回第一个非 #f 的 scope。
(define (active-key-owner ed state)
  (for/or ([c (in-list (registry-contributions
                        (editor-contributions ed) point/key-owner))])
    (define owner (contribution-owner c))
    (with-handlers ([exn:fail? (λ (_e) #f)])
      ((contribution-fn c) ed state (plugin-state-of state owner)))))

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
  ;; registry 在 editor 生命周期内不变，按 scope 缓存派生表。
  (hash-ref! (editor-command-table-cache ed) scope
             (λ ()
               (command-bindings->table (editor-command-bindings ed scope)))))
