#lang racket

;;; edit-tui-rebuild/test/env.rkt —— 块 2：keymap / role / mode / scope / command / env
;;;
;;; 运行：racket edit-tui-rebuild/test/env.rkt

(require rackunit
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         "../base/keymap.rkt"
         "../base/status-part.rkt"
         "../base/transition.rkt"
         "../env/role.rkt"
         "../env/mode.rkt"
         "../env/scope.rkt"
         "../env/command.rkt"
         "../env/rule.rkt"
         "../env/hook.rkt"
         "../env/environment.rkt"
         "../env/defaults.rkt"
         "../model/state.rkt")

;;; ════════════════ keymap ════════════════

(define km
  (keys
   ['a 'cmd-a]
   [(key 'x 'ctrl) (key 's 'ctrl) 'cmd-xs]
   [(key 'x 'ctrl) (key 'y 'ctrl) (key 'z 'ctrl) 'cmd-xyz]
   [(mouse 'press 'left) 'mouse-left]
   [(key 'q) 'save]
   ['nil #f]))

(define-values (s1 v1) (keymap-lookup km '(a)))
(check-eq? s1 'leaf)
(check-eq? v1 'cmd-a)

(define-values (s2 v2) (keymap-lookup km (list (key 'x 'ctrl))))
(check-eq? s2 'prefix)
(check-false v2)

(define-values (s3 v3) (keymap-lookup km (list (key 'x 'ctrl) (key 's 'ctrl))))
(check-eq? s3 'leaf)
(check-eq? v3 'cmd-xs)

(define-values (s4 v4) (keymap-lookup km (list (key 'x 'ctrl) (key 'y 'ctrl) (key 'z 'ctrl))))
(check-eq? s4 'leaf)
(check-eq? v4 'cmd-xyz)

(define-values (s5 v5) (keymap-lookup km (list (mouse 'press 'left))))
(check-eq? s5 'leaf)
(check-eq? v5 'mouse-left)

;; value 允许 #f
(define-values (s6 v6) (keymap-lookup km '(nil)))
(check-eq? s6 'leaf)
(check-false v6)

(check-eq? (keymap-ref km '(a)) 'cmd-a)
(check-true (keymap-prefix? km (list (key 'x 'ctrl))))
(check-false (keymap-prefix? km '(a)))
(check-equal? (call-with-values (λ () (keymap-lookup km '(nope))) list) '(unbound #f))

;;; ════════════════ role ════════════════

(define r-editor (make-role #:splittable? #t #:close 'keep-last #:focusable? #t))
(check-true (role-splittable? r-editor))
(check-eq? (role-close-policy r-editor) 'keep-last)
(check-true (role-focusable? r-editor))

(check-false (role-splittable? role-default))
(check-eq? (role-close-policy role-default) 'hide)
(check-false (role-focusable? role-default))
(check-exn exn:fail? (λ () (make-role #:close 'nope)))

;;; ════════════════ mode ════════════════

(define m-text (make-mode #:keymaps (list km) #:fallback 'insert))
(check-equal? (mode-keymaps m-text) (list km))
(check-eq? (mode-fallback m-text) 'insert)
(check-equal? (mode-keymaps mode-default) '())
(check-eq? (mode-fallback mode-default) 'ignore)
(check-exn exn:fail? (λ () (make-mode #:fallback 'nope)))
(check-exn exn:fail? (λ () (make-mode #:keymaps (list 'not-a-keymap))))

;;; ════════════════ scope ════════════════

(define scopes
  (hash 'never (make-scope (λ (s) #f))
        'has-focus (make-scope (λ (s) (and (state-focus s) #t)))))

(define s0 (state-empty))
(check-true (scope-ok? scopes s0 'always))
(check-false (scope-ok? scopes s0 'never))
(check-false (scope-ok? scopes s0 'has-focus))
(check-false (scope-ok? scopes s0 'unknown))
(check-true (scope-known? scopes 'always))
(check-true (scope-known? scopes 'never))
(check-false (scope-known? scopes 'unknown))

;;; ════════════════ command / environment ════════════════

(define c-save
  (cmd (λ (ctx) ctx) #:note "save" #:input (command-input-spec 'string "file: " #f)))
(check-eq? (command-note c-save) "save")
(check-eq? (command-note-text c-save) "save")
(check-true (command-needs-input? c-save))
(check-eq? (command-run/ctx c-save 'CTX) 'CTX)

(define env0 (environment-empty))
(check-equal? (environment-role env0 'editor) role-default)
(check-equal? (environment-mode env0 'text) mode-default)
(check-false (environment-command env0 'save))
(check-equal? (environment-keymap env0 'global) empty-keymap)
(check-equal? (environment-hooks env0) '())

(define env1
  (environment-add-role
   (environment-add-mode
    (environment-add-scope
     (environment-add-command
      (environment-add-keymap env0 'global km)
      'save c-save)
     'never (hash-ref scopes 'never))
    'text m-text)
   'editor r-editor))

(check-eq? (environment-role env1 'editor) r-editor)
(check-eq? (environment-mode env1 'text) m-text)
(check-eq? (environment-command env1 'save) c-save)
(check-eq? (environment-keymap env1 'global) km)
(check-equal? (environment-mode-keymaps env1 'text) (list km))
(check-eq? (environment-role env1 'nope) role-default)

;; 命令 id 作为 keymap 叶子：查表 -> id -> 命令
(define-values (ks kv) (keymap-lookup (environment-keymap env1 'global) (list (key 'q))))
(check-eq? ks 'leaf)
(check-eq? kv 'save)
(check-eq? (environment-command env1 kv) c-save)

;; merge：b 覆盖 a，未覆盖的保留
(define env2
  (environment-merge env1
                     (environment-add-role (environment-empty)
                                           'editor
                                           (make-role #:splittable? #f #:close 'hide))))
(check-eq? (role-close-policy (environment-role env2 'editor)) 'hide)
(check-eq? (environment-command env2 'save) c-save)
(check-eq? (environment-keymap env2 'global) km)

;; 规则：新规则在前；merge 时 b 的规则优先
(define rule1 (make-rule 'always km))
(define rule2 (make-rule 'always (keys [(key 'q) 'save])))
(define env4 (environment-add-rule env2 rule1))
(check-equal? (environment-rules env4) (list rule1))
(check-equal? (environment-rules
               (environment-merge env4 (make-environment #:rules (list rule2))))
              (list rule2 rule1))

;; 状态栏段：environment.status 默认 #f，新增段放最前
(define part1 (make-status-part 'p1 (λ (s e) "one")))
(define part2 (make-status-part 'p2 (λ (s e) "two")))
(check-false (environment-status (environment-empty)))
(define env5 (environment-add-status-part (environment-empty) part1))
(check-equal? (environment-status env5) (list part1))
(check-equal? (environment-status (environment-add-status-part env5 part2))
              (list part2 part1))

;; hook（内部事件 / tick 也是信号，统一走这一套）
(define env3
  (environment-add-hook env2 (make-hook 'job-done (λ (s ev args) (transition-pure s)))))
(check-equal? (length (environment-hooks env3)) (add1 (length (environment-hooks env2))))

;;; ════════════════ defaults ════════════════

(check-true (role-focusable? (environment-role default-environment 'editor)))
(check-true (role-splittable? (environment-role default-environment 'editor)))
(check-eq? (role-close-policy (environment-role default-environment 'editor)) 'keep-last)
(check-false (role-focusable? (environment-role default-environment 'panel)))
(check-eq? (role-close-policy (environment-role default-environment 'slot)) 'ignore)
(check-eq? (mode-fallback (environment-mode default-environment 'text)) 'insert)
(check-eq? (mode-fallback (environment-mode default-environment 'status)) 'ignore)
(check-eq? (mode-fallback (environment-mode default-environment 'input)) 'insert)

(displayln "edit-tui-rebuild env: ok")
