#lang racket

;;; edit-tui-rebuild/test/plugin.rkt —— 插件描述符 + 纯装配
;;;
;;; 覆盖：
;;;   1. state.store：读写 / 不可变 / 默认值；
;;;   2. plugins-apply：env 合并、状态栏段**追加**（不是替换）、state-init 执行；
;;;   3. 插件命令通过键表派发（headless process-events）；
;;;   4. 插件不在 env 里时，命令就是“unknown command”——证明默认 env 没被污染；
;;;   5. environment-merge 的 status 仍是覆盖语义（与插件追加语义区分开）。

(require rackunit
         racket/async-channel
         racket/string
         "../../edit-tui/command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/keymap.rkt"
         "../base/status.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/rule.rkt"
         "../projection/status.rkt"
         "../bootstrap/chrome.rkt"
         "../bootstrap/defaults.rkt"
         "../bootstrap/plugin.rkt"
         "../dispatch/context.rkt"
         "../runtime/run.rkt")

;;; ════════════════ 1. store ════════════════

(define s0 (make-state))
(check-eq? (plugin-state s0 'thing 'absent) 'absent)
(check-equal? (state-store s0) (hash))
(define s1 (plugin-state-set s0 'thing 42))
(check-equal? (plugin-state s1 'thing) 42)
;; 原 state 不变（纯）
(check-eq? (plugin-state s0 'thing 'absent) 'absent)
(check-equal? (plugin-state (plugin-state* s1 'thing add1) 'thing) 43)
;; 不同插件的槽互不影响
(check-eq? (plugin-state (plugin-state-set s1 'other 'x) 'thing) 42)
(check-equal? (plugin-state (plugin-state* s0 'nope add1 10) 'nope) 11)
;; 默认 make-state 带空 store（不是 #f）
(check-true (hash? (state-store (make-state))))

;;; ════════════════ 2. plugins-apply ════════════════

(define ping-keys (keys [(key 'p) 'ping]))
(define ping-part (make-status-part 'ping (λ (state ev) "ping!")))

(define ping-plugin
  (make-plugin
   'ping
   #:env (make-environment
          #:commands (hash 'ping (cmd (λ (ctx) (transition-pure (ctx-state ctx)))))
          #:rules (list (make-rule 'always ping-keys)))
   #:status-parts (list ping-part)
   #:state-init (λ (s) (plugin-state-set s 'ping 0))))

(define-values (env1 st1) (plugins-apply default-env s0 (list ping-plugin)))
;; env：命令 / 规则进来了
(check-true (command? (environment-command env1 'ping)))
(check-false (environment-command default-env 'ping))
;; 状态栏段：追加在最前，原有段还在（不是替换）
(define parts1 (environment-status env1))
(check-equal? (status-part-name (car parts1)) 'ping)
(check-equal? (length parts1) (add1 (length (environment-status default-env))))
;; state-init 写了插件槽
(check-equal? (plugin-state st1 'ping) 0)
;; 空插件表 = 恒等
(define-values (env0 st0) (plugins-apply default-env s0 '()))
(check-eq? (environment-status env0) (environment-status default-env))
(check-eq? (state-store st0) (state-store s0))

;; 多个插件依次应用
(define-values (env2 st2)
  (plugins-apply default-env s0 (list ping-plugin
                                      (make-plugin 'two #:state-init (λ (s) (plugin-state-set s 'two 2))))))
(check-equal? (plugin-state st2 'two) 2)
(check-equal? (plugin-state st2 'ping) 0)

;;; ════════════════ 3. 键表派发 ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define erid (region-id 1))
(define crid (region-id 2))
(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt" "abc\n"))
(void (engine-create-view! engine vid did))
(define ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did (make-doc-meta "main.rkt" #:path "/tmp/main.rkt"))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws erid (region erid (list (view-member vid)) vid 'editor))])
    ws))
(define base (make-state #:workspace ws #:ids (make-id-counter 2 2 3 1)))
(define with-chrome (install-chrome! engine base crid))
(define lay (make-split 'tb (list (make-leaf erid (flex 1))
                                  (make-leaf crid (fixed 1) #:borders '()))
                        (flex 1)))
(define st-base
  (state-set-focus
   (state-set-workspace with-chrome
                        (struct-copy workspace (state-workspace with-chrome) [layout lay]))
   vid))

(define (feed env s . evs)
  (transition-state (process-events env engine (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))

;; 打一次 ping：计数 +1，并留 message（证明命令真的跑了）
(define hit-plugin
  (make-plugin
   'ping
   #:env (make-environment
          #:commands (hash 'ping (cmd (λ (ctx)
                                        (define s (plugin-state* (ctx-state ctx) 'ping add1 0))
                                        (transition-pure
                                         (state-chrome* s (λ (c)
                                                            (chrome-set-message
                                                             c (format "pong ~a"
                                                                       (plugin-state s 'ping)))))))))
          #:rules (list (make-rule 'always ping-keys)))
   #:status-parts (list ping-part)
   #:state-init (λ (s) (plugin-state-set s 'ping 0))))
(define-values (env3 st3) (plugins-apply default-env st-base (list hit-plugin)))
(define st4 (feed env3 st3 (plain 'p)))
(check-equal? (plugin-state st4 'ping) 1)
(check-equal? (chrome-message (state-chrome st4)) "pong 1")
;; 同一个键在默认 env 下不是命令：不计数，只留 unbound/插入提示
(define st5 (feed default-env st3 (plain 'p)))
(check-equal? (plugin-state st5 'ping) 0)

;;; ════════════════ 3b. 状态栏段真的被投影 ════════════════

;; 参数 provider 走 sync-chrome!：插件的段在前，消息在后。
(sync-chrome! st4 engine (environment-status env3))
(define status-text
  (engine-view-view-text (make-engine-view engine) (chrome-status-view st4)))
(check-true (string-contains? status-text "ping!"))
(check-true (string-contains? status-text "pong 1"))
(check-true (regexp-match? #rx"^ping!  " status-text))

;;; ════════════════ 4. 默认 env 没被污染 ════════════════

(check-false (environment-command default-env 'ping))
(check-false (for/or ([r (in-list (environment-rules default-env))]
                       #:when (eq? (rule-scope r) 'always))
              (define-values (st _)
                (keymap-lookup (rule-keymap r) (list (key 'p))))
              (eq? st 'leaf)))

;;; ════════════════ 5. merge 的 status 仍是覆盖语义 ════════════════

(define only-path (make-environment #:status (list status-path-part)))
(define merged (environment-merge default-env only-path))
(check-equal? (map status-part-name (environment-status merged)) '(path))
