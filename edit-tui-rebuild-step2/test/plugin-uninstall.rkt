#lang racket

;;; edit-tui/test/plugin-uninstall.rkt —— 插件卸载：env + store + panel
;;;
;;; 覆盖：
;;;   1. plugin-uninstall! 撤销 owner 的 env 贡献；
;;;   2. 清掉 store[owner]；
;;;   3. #:regions 里的面板被 panel-uninstall! 拆掉（doc / view / region / layout）；
;;;   4. 不传 #:regions 时只做 env + store，不猜布局。

(require rackunit
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/engine.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/extension.rkt"
         "../env/plugin.rkt"
         "../env/panel-spec.rkt"
         "../bootstrap/panel.rkt"
         "../bootstrap/plugin.rkt"
         "../dispatch/context.rkt")

(define (noop-command)
  (cmd (λ (ctx) (transition-pure (ctx-state ctx)))))

(define owner 'uninstall-demo)
(define rid (region-id 1))

(define plugin
  (make-plugin
   owner
   #:contributions
   (list (make-contribution owner 'command
                            (cons 'uninstall-cmd (noop-command))))))

(define env (plugins-env (environment-empty) (list plugin)))

;; 一个面板 + 一个 layout leaf（panel-spec-install! 本身不管布局位置）
(define engine (make-engine))
(define state0 (make-state #:ids (make-id-counter 1 1 2 1)))
(define-values (state1 pvid)
  (panel-spec-install! engine state0 rid
                       (make-panel-spec #:name "*uninstall-demo*"
                                        #:role 'panel
                                        #:mode 'text
                                        #:sync #f)))
(define state2
  (state-workspace* state1
                    (λ (ws)
                      (struct-copy workspace ws
                                   [layout (make-leaf rid)]))))
(define state3 (plugin-state-set state2 owner 'plugin-state))

(check-true (command? (environment-command env 'uninstall-cmd)))
(check-true (engine-view-exists? engine pvid))
(check-true (and (workspace-region (state-workspace state3) rid) #t))
(check-true (tree-contains? (workspace-layout (state-workspace state3)) rid))

;; 卸载：env + store + panel
(define-values (env* state*)
  (plugin-uninstall! engine state3 env owner #:regions (list rid)))

(check-false (environment-command env* 'uninstall-cmd))
(check-false (for/or ([c (in-list (environment-contributions env*))])
               (eq? (contribution-owner c) owner)))
(check-eq? (plugin-state state* owner 'absent) 'absent)
(check-false (engine-view-exists? engine pvid))
(check-false (workspace-region (state-workspace state*) rid))
(check-false (tree-contains? (workspace-layout (state-workspace state*)) rid))
(check-equal? (hash-count (workspace-docs (state-workspace state*))) 0)
(check-equal? (hash-count (workspace-views (state-workspace state*))) 0)

;; 不传 #:regions：只撤 env + store，面板留给宿主
(define engine2 (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 2 1)))
(define-values (s1 v2)
  (panel-spec-install! engine2 s0 rid
                       (make-panel-spec #:name "*keep*" #:role 'panel
                                        #:mode 'text #:sync #f)))
(define s2 (plugin-state-set s1 owner 'x))
(define env2 (plugins-env (environment-empty) (list plugin)))
(define-values (env2* s2*)
  (plugin-uninstall! engine2 s2 env2 owner))
(check-false (environment-command env2* 'uninstall-cmd))
(check-eq? (plugin-state s2* owner 'absent) 'absent)
(check-true (engine-view-exists? engine2 v2))
(check-true (and (workspace-region (state-workspace s2*) rid) #t))

(displayln "edit-tui plugin-uninstall: ok")

;;; ════════════════ panel-spec install 回调 ════════════════

(define engine3 (make-engine))
(define install-args #f)
(define install-spec
  (make-panel-spec #:name "*install*" #:role 'panel #:mode 'text #:sync #f
                   #:install
                   (λ (e s rid vid)
                     (set! install-args (list rid vid))
                     (plugin-state-set s 'installed vid))))
(define-values (s-install vid-install)
  (panel-spec-install! engine3 (make-state #:ids (make-id-counter 1 1 2 1))
                       rid install-spec))
(check-equal? install-args (list rid vid-install))
(check-eq? (plugin-state s-install 'installed) vid-install)
(check-true (engine-view-exists? engine3 vid-install))

;;; ════════════════ panel-spec hint ════════════════

(define engine4 (make-engine))
(define layout-state
  (state-workspace*
   (make-state #:ids (make-id-counter 1 1 2 1))
   (λ (ws) (struct-copy workspace ws [layout (make-leaf rid (flex 1))]))))
(define hint-spec
  (make-panel-spec #:name "*hint*" #:role 'panel #:mode 'text #:sync #f
                   #:hint (fixed 42)))
(define-values (s-hint _v-hint)
  (panel-spec-install! engine4 layout-state rid hint-spec))
(define hint-leaf (tree-find (workspace-layout (state-workspace s-hint)) rid))
(check-true (dim-fixed? (leaf-dim hint-leaf)))
(check-equal? (dim-value (leaf-dim hint-leaf)) 42)

;;; ════════════════ panel registry + 自动卸载 ════════════════

(define (auto-plugin id)
  (make-plugin
   id
   #:contributions
   (list (make-contribution id 'command
                            (cons (string->symbol (format "~a-cmd" id))
                                  (noop-command))))))

(define env-auto (plugins-env (environment-empty)
                              (list (auto-plugin 'auto-a)
                                    (auto-plugin 'auto-b))))

(define engine6 (make-engine))
(define s-auto0
  (state-workspace*
   (make-state #:ids (make-id-counter 1 1 2 1))
   (λ (ws) (struct-copy workspace ws [layout (make-leaf rid (flex 1))]))))
(define-values (s-auto1 vid-a)
  (panel-spec-install! engine6 s-auto0 rid
                       (make-panel-spec #:name "*auto-a*" #:role 'panel
                                        #:mode 'text #:sync #f
                                        #:owner 'auto-a #:key 'main)))
(define-values (s-auto2 vid-b)
  (panel-spec-install! engine6 s-auto1 rid
                       (make-panel-spec #:name "*auto-b*" #:role 'panel
                                        #:mode 'text #:sync #f
                                        #:owner 'auto-b #:key 'main)))

(check-eq? (workspace-panel-view (state-workspace s-auto2) 'auto-a 'main) vid-a)
(check-eq? (workspace-panel-view (state-workspace s-auto2) 'auto-b 'main) vid-b)
(check-eq? (workspace-panel-region (state-workspace s-auto2) 'auto-a 'main) rid)

;; 只卸 auto-a：共享 region 里的 auto-b 必须保留
(define s-auto3 (plugin-state-set s-auto2 'auto-a 'x))
(define-values (env-auto* s-auto4)
  (plugin-uninstall! engine6 s-auto3 env-auto 'auto-a))
(check-false (command? (environment-command env-auto* 'auto-a-cmd)))
(check-true (command? (environment-command env-auto* 'auto-b-cmd)))
(check-eq? (plugin-state s-auto4 'auto-a 'absent) 'absent)
(check-false (engine-view-exists? engine6 vid-a))
(check-true (engine-view-exists? engine6 vid-b))
(check-true (and (workspace-region (state-workspace s-auto4) rid) #t))
(check-eq? (workspace-panel-view (state-workspace s-auto4) 'auto-b 'main) vid-b)
(check-false (workspace-panel-view (state-workspace s-auto4) 'auto-a 'main))

;; 再卸 auto-b：region 空了才连 region / layout 一起收掉
(define-values (env-auto2 s-auto5)
  (plugin-uninstall! engine6 s-auto4 env-auto* 'auto-b))
(check-false (engine-view-exists? engine6 vid-b))
(check-false (workspace-region (state-workspace s-auto5) rid))
(check-false (tree-contains? (workspace-layout (state-workspace s-auto5)) rid))

;;; ════════════════ panel-spec placement ════════════════

(define engine7 (make-engine))
(define s-place0
  (state-workspace*
   (make-state #:ids (make-id-counter 1 1 2 1))
   (λ (ws) (struct-copy workspace ws [layout (make-leaf rid (flex 1))]))))
(define-values (s-place1 place-a)
  (panel-spec-install! engine7 s-place0 rid
                       (make-panel-spec #:name "*place-a*" #:role 'panel
                                        #:mode 'text #:sync #f
                                        #:owner 'place-a #:key 'main)))
(define-values (s-place2 place-b)
  (panel-spec-install! engine7 s-place1 rid
                       (make-panel-spec #:name "*place-b*" #:role 'panel
                                        #:mode 'text #:sync #f
                                        #:owner 'place-b #:key 'main
                                        #:placement 'inactive)))
(define place-reg (workspace-region (state-workspace s-place2) rid))
;; 第二个面板加进成员表，但不抢 active
(check-equal? (region-active place-reg) place-a)
(check-equal? (length (workspace-region-views (state-workspace s-place2) rid)) 2)
(check-eq? (workspace-panel-view (state-workspace s-place2) 'place-b 'main) place-b)
