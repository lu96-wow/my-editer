#lang racket

;;; edit-tui-rebuild/test/dispatch.rkt —— 块 3：规则管线 / 键盘 / 鼠标
;;;
;;; 运行：racket edit-tui-rebuild/test/dispatch.rkt

(require rackunit
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         "../base/id.rkt"
         "../base/event.rkt"
         "../base/effect.rkt"
         "../base/keymap.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../env/role.rkt"
         "../env/mode.rkt"
         "../env/command.rkt"
         "../env/scope.rkt"
         "../env/rule.rkt"
         "../env/environment.rkt"
         "../env/defaults.rkt"
         "../dispatch/context.rkt"
         "../dispatch/rules.rkt"
         "../dispatch/pipeline.rkt")

;;; ════════════════ 测试世界 ════════════════

(define (plain c) (key-event (key c)))
(define (ctrl c)  (key-event (key c 'ctrl)))
(define (alt c)   (key-event (key c 'alt)))
(define (mouse-ev a b) (mouse-event (mouse a b) 1 1))

(define (state* #:focus [focus #f] #:modes [modes '()] #:pending [pending '()]
                #:doc-layers [doc-layers '()])
  (define did (doc-id 1))
  (define v1 (view-id 1))
  (define v2 (view-id 2))
  (define r1 (region-id 1))
  (define ws (workspace-empty))
  (define ws* (workspace-add-doc ws did (make-doc-meta "main.rkt" #:mode 'text
                                                       #:keymap-layers doc-layers)))
  (define ws** (workspace-add-view ws* v1 (view-meta did (hash))))
  (define ws*** (workspace-add-view ws** v2 (view-meta did (hash))))
  (define ws**** (workspace-add-region ws*** r1
                                       (region r1
                                               (list (view-member v1) (view-member v2))
                                               v1
                                               'editor)))
  (define ws***** (struct-copy workspace ws**** [layout (make-leaf r1)]))
  (define in (make-input #:pending pending #:modes modes))
  (define s (make-state #:workspace ws***** #:input in))
  (define s* (if focus (state-set-focus s focus) s))
  (values s* v1 v2 r1))

;; 基础命令：no-op / 记录 note / 插入 effect
(define (cmd-noop note)
  (cmd (λ (ctx) (transition-pure (ctx-state ctx))) #:note note))

(define (cmd-note note)
  (cmd (λ (ctx)
         (transition-pure
          (state-chrome* (ctx-state ctx)
                         (λ (c) (chrome-set-message c note)))))))

(define (cmd-insert text)
  (cmd (λ (ctx)
         (transition (ctx-state ctx)
                     (list (insert-text-effect (ctx-subject ctx) text))))))

;; 键表
(define mode-km
  (keys
   [(key 'a) 'note-mode]
   [(key 'x 'ctrl) (key 's 'ctrl) 'note-xs]
   [(key 'x 'ctrl) (key 'y 'ctrl) (key 'z 'ctrl) 'note-xyz]  ; C-x C-y 是前缀
   [(mouse 'press 'left) 'note-click]))

(define overlay-km
  (keys [(key 'a) 'note-overlay]))

(define doc-km
  (keys [(key 'a) 'note-doc]))

(define prefix-km
  (keys [(key 'd 'ctrl) 'prefix-back]
        [(key 'g 'ctrl) 'prefix-clear]))

(define global-km
  (keys [(key 'q 'ctrl) 'quit-cmd]))

;; 命令表
(define commands
  (hash 'note-mode      (cmd-note "mode")
        'note-overlay   (cmd-note "overlay")
        'note-doc       (cmd-note "doc")
        'note-xs        (cmd-note "xs")
        'note-xyz       (cmd-note "xyz")
        'note-click     (cmd-note "click")
        'prefix-back    (cmd (λ (ctx)
                               (transition-pure
                                (state-input* (ctx-state ctx) input-clear-pending))))
        'prefix-clear   (cmd (λ (ctx)
                               (transition-pure
                                (state-input* (ctx-state ctx) input-clear-pending))))
        'quit-cmd       (cmd (λ (ctx) (transition-pure (state-mark-quit (ctx-state ctx)))))))

;; 环境
(define env
  (environment-merge
   default-environment
   (make-environment
    #:modes (hash 'text (make-mode #:keymaps (list mode-km) #:fallback 'insert))
    #:commands commands
    #:keymaps (hash 'global global-km
                    'overlay overlay-km
                    'doc doc-km
                    'prefix prefix-km))))

;;; ════════════════ 键盘：mode 表 ════════════════

(define-values (s0 v1 v2 r1) (state* #:focus (view-id 1)))
(define t0 (dispatch env s0 (plain 'a)))
(check-equal? (chrome-message (state-chrome (transition-state t0))) "mode")
(check-equal? (transition-effects t0) '())
(check-equal? (state-input (transition-state t0)) (state-input s0)) ; 无 pending
(check-equal? (runtime-revision (state-runtime (transition-state t0)))
              (add1 (runtime-revision (state-runtime s0))))

;;; ════════════════ 键盘：prefix ════════════════

(define t1 (dispatch env s0 (ctrl 'x)))
(check-equal? (input-pending (state-input (transition-state t1))) (list (key 'x 'ctrl)))
(check-equal? (transition-effects t1) '())

(define t2 (dispatch env (transition-state t1) (ctrl 's)))
(check-equal? (chrome-message (state-chrome (transition-state t2))) "xs")
(check-equal? (input-pending (state-input (transition-state t2))) '())

;; C-x C-y 是前缀；再按 z 才...（这里只验证停在 prefix）
(define t3 (dispatch env s0 (ctrl 'x)))
(define t4 (dispatch env (transition-state t3) (ctrl 'y)))
(check-equal? (input-pending (state-input (transition-state t4)))
              (list (key 'x 'ctrl) (key 'y 'ctrl)))

;; prefix 编辑：pending 非空时 C-d 单独查 prefix 表
(define t5 (dispatch env (transition-state t4) (ctrl 'd)))
(check-equal? (input-pending (state-input (transition-state t5))) '())

;; 未命中：fallback insert -> insert-text-effect
(define t6 (dispatch env s0 (plain 'z)))
(check-equal? (length (transition-effects t6)) 1)
(check-true (insert-text-effect? (car (transition-effects t6))))
(check-equal? (insert-text-effect-view (car (transition-effects t6))) v1)
(check-equal? (insert-text-effect-text (car (transition-effects t6))) "z")

;; 未命中：不可打印 -> chrome 消息
(define t7 (dispatch env s0 (key-event (key 'left))))
(check-true (string-contains? (chrome-message (state-chrome (transition-state t7))) "unbound"))

;;; ════════════════ 键盘：层序 ════════════════

;; input mode 最高
(define-values (s-mode v1* v2* r1*) (state* #:focus (view-id 1) #:modes '(overlay)))
(define t8 (dispatch env s-mode (plain 'a)))
(check-equal? (chrome-message (state-chrome (transition-state t8))) "overlay")

;; per-doc 层高于 mode
(define-values (s-doc v1** v2** r1**) (state* #:focus (view-id 1) #:doc-layers (list doc-km)))
(define t9 (dispatch env s-doc (plain 'a)))
(check-equal? (chrome-message (state-chrome (transition-state t9))) "doc")

;; global 低于 mode
(define-values (s-global v1*** v2*** r1***) (state* #:focus (view-id 1)))
(define t10 (dispatch env s-global (ctrl 'q)))
(check-true (runtime-quit? (state-runtime (transition-state t10))))

;;; ════════════════ 鼠标 ════════════════

;; 鼠标命令按 subject 查表（不是 focus）
(define t19 (dispatch env s0 (mouse-ev 'press 'left) #:subject v2))
(check-equal? (chrome-message (state-chrome (transition-state t19))) "click")

;; 无命令：press 聚焦 focusable subject
(define t20 (dispatch env s0 (mouse-ev 'press 'middle) #:subject v2))
(check-equal? (state-focus (transition-state t20)) v2)

;; release 清 gesture
(define s21 (state-input* s0 (λ (i) (input-set-gesture i (make-gesture 'seam #f 'x)))))
(define t21 (dispatch env s21 (mouse-ev 'release 'left) #:subject v2))
(check-false (input-gesture (state-input (transition-state t21))))

;; scroll 产出 scroll-effect
(define t22 (dispatch env s0 (mouse-ev 'scroll 'down) #:subject v2))
(check-equal? (effect-kind (car (transition-effects t22))) 'scroll)

;;; ════════════════ 其它事件 ════════════════

;; resize
(define t23 (dispatch env s0 (resize-event 30 100)))
(check-equal? (window-rows (state-window (transition-state t23))) 30)
(check-equal? (window-cols (state-window (transition-state t23))) 100)

;; paste
(define t24 (dispatch env s0 (paste-event "hi") #:subject v1))
(check-equal? (insert-text-effect-text (car (transition-effects t24))) "hi")

;; internal handler
(define env2
  (environment-add-handler env 'job-done
                            (λ (s payload)
                              (transition-pure
                               (state-chrome* s
                                              (λ (c) (chrome-set-message c (format "done ~a" payload))))))))
(define t25 (dispatch env2 s0 (internal-event 'job-done 'v)))
(check-equal? (chrome-message (state-chrome (transition-state t25))) "done v")

;; quit-event
(define t26 (dispatch env s0 (quit-event)))
(check-true (runtime-quit? (state-runtime (transition-state t26))))

;;; ════════════════ 未知命令 / 未注册 mode ════════════════

(define env-bad
  (environment-add-keymap env 'global (keys [(key 'u) 'no-such-command])))
(define t27 (dispatch env-bad s0 (key-event (key 'u))))
(check-true (string-contains? (chrome-message (state-chrome (transition-state t27)))
                              "unknown command"))

;;; ════════════════ 带 scope 的规则层 ════════════════

(define scoped-km (keys [(key 'a) 'note-rule]))
(define scoped-env
  (environment-merge
   env
   (make-environment
    #:scopes (hash 'yes (make-scope (λ (s) #t))
                   'no  (make-scope (λ (s) #f)))
    #:rules (list (make-rule 'yes scoped-km)
                  (make-rule 'no scoped-km))
    #:commands (hash 'note-rule (cmd-note "rule")))))

;; scope 成立：规则在 mode 之前，覆盖 mode 的 'a
(define t-rule (dispatch scoped-env s0 (plain 'a)))
(check-equal? (chrome-message (state-chrome (transition-state t-rule))) "rule")

;; scope 不成立：规则被过滤，落回 mode
(define no-scope-env
  (environment-merge
   env
   (make-environment
    #:scopes (hash 'no (make-scope (λ (s) #f)))
    #:rules (list (make-rule 'no scoped-km))
    #:commands (hash 'note-rule (cmd-note "rule")))))
(define t-no-rule (dispatch no-scope-env s0 (plain 'a)))
(check-equal? (chrome-message (state-chrome (transition-state t-no-rule))) "mode")

(displayln "edit-tui-rebuild dispatch: ok")
