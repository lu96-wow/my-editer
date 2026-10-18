#lang racket

;;; edit-tui/test/extension.rkt —— contribution 清单 + 装配期校验
;;;
;;; 覆盖：
;;;   1. contribution 能落到现有 env 字段（command / keymap / rule / mode /
;;;      role / doc-type / status / panel / hook / decor / face-layer）；
;;;   2. owner / kind / payload 被保留，可按 owner 反查；
;;;   3. validate-environment 能抓出：未知命令、未知 scope、未声明 layer、
;;;      重名 status / layer、panel mode / role 未注册；
;;;   4. default-env / editor-env 通过校验；
;;;   5. plugin 的 #:contributions 会被装配并校验。

(require rackunit
         racket/string
         "../command/key.rkt"
         "../base/keymap.rkt"
         "../base/status-part.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/face-decor.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/extension.rkt"
         "../env/hook.rkt"
         "../env/mode.rkt"
         "../env/panel-spec.rkt"
         "../env/plugin.rkt"
         "../env/service.rkt"
         "../env/role.rkt"
         "../env/rule.rkt"
         "../env/scope.rkt"
         "../env/doc-type.rkt"
         "../dispatch/context.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt")

;;; ════════════════ 夹具有效环境 ════════════════

(define (noop-command)
  (cmd (λ (ctx) (transition-pure (ctx-state ctx)))))

(define c-x (noop-command))
(define km (keys [(key 'x) 'x]))
(define sc (make-scope (λ (s) #t)))
(define rule (make-rule 's km))
(define mode (make-mode #:keymaps (list km) #:fallback 'ignore))
(define role (make-role #:splittable? #t #:close 'delete #:focusable? #t #:target? #t))
(define dt (make-doc-type 'demo #:extensions '("demo") #:mode 'm #:keymaps (list km)))
(define p1 (make-status-part 'p1 (λ (s e) "one")))
(define p2 (make-status-part 'p2 (λ (s e) "two")))
(define d1 (face-decor 'd1 'f (λ (dm) #t)
                       (λ (path text) (values #f (blank-layer-track text)))
                       (λ (state layer ctx) (values state layer (dirty-lines '())))))
(define ps (make-panel-spec #:name "*demo*" #:role 'r #:mode 'm
                            #:sync (λ (s e) (void))))

(define good-contributions
  (list (make-contribution 'demo 'command (cons 'x c-x))
        (make-contribution 'demo 'keymap (cons 'km km))
        (make-contribution 'demo 'scope (cons 's sc))
        (make-contribution 'demo 'rule rule)
        (make-contribution 'demo 'mode (cons 'm mode))
        (make-contribution 'demo 'role (cons 'r role))
        (make-contribution 'demo 'doc-type dt)
        (make-contribution 'demo 'face-layer 'f)
        (make-contribution 'demo 'decor d1)
        (make-contribution 'demo 'status-parts (list p1 p2))
        (make-contribution 'demo 'panel ps)))

(define env-good (environment-add-contributions (environment-empty) good-contributions))

;;; ════════════════ 1. contribution -> env 字段 ════════════════

(check-true (command? (environment-command env-good 'x)))
(check-eq? (environment-keymap env-good 'km) km)
(check-eq? (environment-role env-good 'r) role)
(check-eq? (environment-mode env-good 'm) mode)
(check-eq? (environment-doc-type env-good 'demo) dt)
(check-equal? (environment-rules env-good) (list rule))
(check-equal? (environment-status env-good) (list p1 p2))
(check-equal? (environment-panel-syncs env-good) (list (panel-spec-sync ps)))
(check-equal? (environment-face-layers env-good) '(f))
(check-equal? (map face-decor-id (environment-decors env-good)) '(d1))

;;; ════════════════ 2. provenance ════════════════

(check-equal? (length (environment-contributions env-good)) 11)
(check-equal? (map contribution-owner (environment-contributions env-good))
              (make-list 11 'demo))
(check-equal? (length (environment-owner-contributions env-good 'demo)) 11)
(check-equal? (environment-owner-contributions env-good 'other) '())

;;; ════════════════ 3. validate：有效环境 ════════════════

(check-true (environment-valid? env-good))
(check-equal? (validate-environment env-good) '())
(check-eq? (validate-environment! env-good) env-good)

;;; ════════════════ 4. validate：错误 ════════════════

(define (errors-where env where)
  (for/list ([e (in-list (validate-environment env))]
             #:when (eq? (validation-error-where e) where))
    e))

;; 4.1 keymap 指向不存在命令
(define env-bad-command
  (environment-add-keymap (environment-empty) 'global
                          (keys [(key 'a) 'no-such-command])))
(check-true (pair? (errors-where env-bad-command 'keymaps)))

;; 4.2 rule 的 scope 未注册
(define env-bad-scope
  (environment-add-rule (environment-empty)
                        (make-rule 'missing (keys [(key 'a) 'whatever]))))
(check-true (pair? (errors-where env-bad-scope 'rules)))

;; 4.3 decor layer 未声明
(define env-bad-decor (environment-add-decor (environment-empty) d1))
(check-true (pair? (errors-where env-bad-decor 'decors)))

;; 4.4 两个 decor 用同一个 layer
(define d2 (face-decor 'd2 'f (λ (dm) #t)
                       (λ (path text) (values #f (blank-layer-track text)))
                       (λ (state layer ctx) (values state layer (dirty-lines '())))))
(define env-dup-decor
  (environment-add-decors
   (environment-add-face-layer (environment-empty) 'f)
   (list d1 d2)))
(check-true (pair? (errors-where env-dup-decor 'decors)))

;; 4.5 status part 重名
(define env-dup-status
  (environment-add-status-parts (environment-empty) (list p1 p1)))
(check-true (pair? (errors-where env-dup-status 'status)))

;; 4.6 face layer 重名
(define env-dup-layer
  (environment-add-face-layers (environment-empty) '(f f)))
(check-true (pair? (errors-where env-dup-layer 'face-layers)))

;; 4.7 panel 的 mode / role 未注册
(define env-bad-panel
  (environment-add-contribution
   (environment-empty)
   (make-contribution 'bad 'panel
                      (make-panel-spec #:name "*bad*" #:role 'nope #:mode 'nope
                                       #:sync #f))))
(check-true (pair? (errors-where env-bad-panel 'panels)))
(check-true (>= (length (errors-where env-bad-panel 'panels)) 2))

;; 4.8 validate-environment! 抛错
(check-exn (λ (e) (and (exn? e)
                       (string-contains? (exn-message e) "环境校验失败")))
           (λ () (validate-environment! env-bad-command)))

;;; ════════════════ 5. 内置 env 通过校验 ════════════════

(check-true (environment-valid? core-env))
(check-true (environment-valid? default-env))
(check-true (environment-valid? editor-env))

;;; ════════════════ 6. plugin 的 #:contributions ════════════════

(define c-y (noop-command))
(define contrib-plugin
  (make-plugin 'contrib
               #:contributions
               (list (make-contribution 'contrib 'command (cons 'y c-y)))))
(define-values (env-p st-p)
  (plugins-apply (environment-empty) (state-empty) (list contrib-plugin)))
(check-true (command? (environment-command env-p 'y)))
(check-equal? (map contribution-owner (environment-contributions env-p)) '(contrib))
(check-equal? (state-store st-p) (hash))

;; owner 必须等于 plugin id
(check-exn exn:fail?
           (λ ()
             (make-plugin 'other
                          #:contributions
                          (list (make-contribution 'contrib 'command (cons 'y c-y))))))

;; 非法 kind 在 make-contribution 就被挡住
(check-exn exn:fail?
           (λ () (make-contribution 'demo 'nope 'payload)))

(displayln "edit-tui extension: ok")

;;; ════════════════ 6b. interaction contribution ════════════════

(define ihandler (λ (ctx data) (transition-pure (ctx-state ctx))))
(define env-int
  (environment-add-contribution
   (environment-empty)
   (make-contribution 'demo 'interaction (cons 'custom ihandler))))
(check-eq? (environment-interaction env-int 'custom) ihandler)
(check-true (environment-valid? env-int))

;;; ════════════════ 6c. service contribution ════════════════

(define svc-spec (make-service-spec 'demo-svc #:description "demo service"))
(define env-svc
  (environment-add-contribution
   (environment-empty)
   (make-contribution 'demo 'service svc-spec)))
(check-eq? (environment-service env-svc 'demo-svc) svc-spec)
(check-equal? (environment-service-kinds env-svc) '(demo-svc))
(check-true (environment-valid? env-svc))

;;; ════════════════ 7. merge 保留 provenance；旧字段也转成 contribution ════════════════

(define merged (environment-merge env-good (environment-empty)))
(check-equal? (length (environment-contributions merged)) 11)

(define h (make-hook 'after-edit (λ (s ev args) (transition-pure s))))
(define legacy (make-plugin 'legacy #:hooks (list h)))
(define-values (env-legacy _st)
  (plugins-apply (environment-empty) (state-empty) (list legacy)))
(check-true (for/or ([c (in-list (environment-contributions env-legacy))])
              (and (eq? (contribution-owner c) 'legacy)
                   (eq? (contribution-kind c) 'hook)
                   (eq? (contribution-payload c) h))))

;;; ════════════════ 8. owner 重建（environment-remove-owner） ════════════════

(define base-env
  (environment-add-command
   (environment-add-mode
    (environment-empty) 'base-mode (make-mode))
   'base-cmd (noop-command)))

(define base-rule (make-rule 'always (keys [(key #\0) 'base-cmd])))
(define base-env* (environment-add-rule base-env base-rule))

(define p1-rule-a (make-rule 'always (keys [(key 'a) 'p1-a])))
(define p1-rule-b (make-rule 'always (keys [(key 'b) 'p1-b])))
(define p2-rule-a (make-rule 'always (keys [(key 'c) 'p2-a])))
(define p2-rule-b (make-rule 'always (keys [(key 'd) 'p2-b])))
(define p1-part-a (make-status-part 'p1-a (λ (s e) "p1a")))
(define p1-part-b (make-status-part 'p1-b (λ (s e) "p1b")))
(define p2-part   (make-status-part 'p2   (λ (s e) "p2")))
(define p2-sync (λ (s e) (void)))
(define p1-sync (λ (s e) (void)))
(define p1-panel (make-panel-spec #:name "*p1*" #:role 'p1-role #:mode 'p1-mode
                                  #:sync p1-sync))
(define p2-panel (make-panel-spec #:name "*p2*" #:role 'p2-role #:mode 'p2-mode
                                  #:sync p2-sync))
(define p1-hook (make-hook 'after-edit (λ (s ev args) (transition-pure s))))
(define p2-hook (make-hook 'after-nav (λ (s ev args) (transition-pure s))))
(define p1-decor (face-decor 'p1-decor 'p1-f (λ (dm) #t)
                            (λ (path text) (values #f (blank-layer-track text)))
                            (λ (state layer ctx) (values state layer (dirty-lines '())))))
(define p2-decor (face-decor 'p2-decor 'p2-f (λ (dm) #t)
                            (λ (path text) (values #f (blank-layer-track text)))
                            (λ (state layer ctx) (values state layer (dirty-lines '())))))

(define p1-owner
  (make-plugin
   'p1
   #:env (make-environment
          #:commands (hash 'p1-a (noop-command) 'p1-b (noop-command))
          #:modes (hash 'p1-mode (make-mode #:keymaps (list (keys [(key 'a) 'p1-a]))))
          #:roles (hash 'p1-role (make-role))
          #:rules (list p1-rule-a p1-rule-b)
          #:face-layers (list 'p1-f))
   #:status-parts (list p1-part-a p1-part-b)
   #:panels (list p1-panel)
   #:hooks (list p1-hook)
   #:decors (list p1-decor)))

(define p2-owner
  (make-plugin
   'p2
   #:env (make-environment
          #:commands (hash 'p2-a (noop-command) 'p2-b (noop-command))
          #:modes (hash 'p2-mode (make-mode #:keymaps (list (keys [(key 'c) 'p2-a]))))
          #:roles (hash 'p2-role (make-role))
          #:rules (list p2-rule-a p2-rule-b)
          #:face-layers (list 'p2-f))
   #:status-parts (list p2-part)
   #:panels (list p2-panel)
   #:hooks (list p2-hook)
   #:decors (list p2-decor)))

(define env-both (plugins-env base-env* (list p1-owner p2-owner)))
(check-true (environment-valid? env-both))
(check-equal? (map rule-scope (environment-rules env-both)) '(always always always always always))
(check-equal? (map status-part-name (environment-status env-both)) '(p2 p1-a p1-b))
(check-equal? (environment-face-layers env-both) '(p1-f p2-f))

;; 去掉 p1：p2 / base 仍在，p1 的字段全部消失
(define env-no-p1 (environment-remove-owner env-both 'p1))
(check-true (environment-valid? env-no-p1))
(check-true (command? (environment-command env-no-p1 'base-cmd)))
(check-true (command? (environment-command env-no-p1 'p2-a)))
(check-false (environment-command env-no-p1 'p1-a))
(check-false (hash-has-key? (environment-modes env-no-p1) 'p1-mode))
(check-equal? (environment-rules env-no-p1) (list p2-rule-a p2-rule-b base-rule))
(check-equal? (map status-part-name (environment-status env-no-p1)) '(p2))
(check-equal? (environment-face-layers env-no-p1) '(p2-f))
(check-equal? (map face-decor-id (environment-decors env-no-p1)) '(p2-decor))
(check-equal? (environment-hooks env-no-p1) (list p2-hook))
(check-true (and (memq p2-sync (environment-panel-syncs env-no-p1)) #t))
(check-false (memq p1-sync (environment-panel-syncs env-no-p1)))
(check-true (for/or ([c (in-list (environment-contributions env-no-p1))])
              (eq? (contribution-owner c) 'p2)))
(check-false (for/or ([c (in-list (environment-contributions env-no-p1))])
               (eq? (contribution-owner c) 'p1)))

;; 再去掉 p2：回到 base
(define env-base-only (environment-remove-owner env-no-p1 'p2))
(check-true (environment-valid? env-base-only))
(check-true (command? (environment-command env-base-only 'base-cmd)))
(check-false (environment-command env-base-only 'p2-a))
(check-equal? (environment-rules env-base-only) (list base-rule))
(check-false (environment-status env-base-only))
(check-equal? (environment-hooks env-base-only) '())
(check-equal? (environment-decors env-base-only) '())
(check-equal? (environment-panel-syncs env-base-only) '())

;; 去掉不存在的 owner = 原样
(check-eq? (environment-remove-owner env-both 'nope) env-both)

;; 没有 base 快照的环境不能按 owner 重建
(check-exn exn:fail?
           (λ () (environment-remove-owner (environment-empty) 'p1)))
