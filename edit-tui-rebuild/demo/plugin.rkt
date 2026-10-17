#lang racket

;;; edit-tui-rebuild/demo/plugin.rkt —— 最小插件：**不改框架任何文件**
;;;
;;;   racket edit-tui-rebuild/demo/plugin.rkt
;;;
;;; 这个 demo 只做一件事：证明一个插件可以用纯数据接到骨架上。
;;; 插件贡献了四样东西：
;;;
;;;   1. 命令   'demo-hi           （plugin 自己的逻辑）
;;;   2. 键表   h -> 'demo-hi      （通过 env.rules，scope 'always）
;;;   3. 状态   自己的 store 槽    （state-init + plugin-state*）
;;;   4. 状态栏 一段 "hi×N"        （status-parts，加法语义）
;;;
;;; 框架侧没有为它新增一个字段、一个 cond 分支或一个 require。
;;;
;;; 键位：h 打招呼并计数 / ←→↑↓ Home End 移动 / C-q 退出
;;;
;;; 对外：(demo-plugin) 与 (plugin-demo) 由 module+ main 之外的宿主复用，
;;; 所以 require 本文件没有副作用（不建 engine、不跑终端）。

(provide demo-plugin
         demo-count
         plugin-demo)

(require racket/string
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../base/keymap.rkt"
         "../base/status-part.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/rule.rkt"
         "../chrome/slot.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../env/plugin.rkt"
         "../dispatch/context.rkt"
         "../runtime/run.rkt")

;;; ════════════════ 插件：状态 ════════════════

;; store 槽的值 = 打招呼次数（integer）。插件自己决定表示法。
(define (demo-count state) (plugin-state state 'demo 0))

;;; ════════════════ 插件：命令 ════════════════

(define (hi-command)
  (cmd (λ (ctx)
         (define s1 (plugin-state* (ctx-state ctx) 'demo add1 0))
         (transition-pure
          (state-chrome*
           s1
           (λ (c) (chrome-set-message c (format "hello #~a" (demo-count s1)))))))))

(define demo-commands
  (hash 'demo-hi (hi-command)))

;;; ════════════════ 插件：键表 + 规则 ════════════════

(define demo-keys
  (keys [(key 'h) 'demo-hi]))

;;; ════════════════ 插件：状态栏段 ════════════════

(define demo-status-part
  (make-status-part
   'demo
   (λ (state ev) (format "hi×~a" (demo-count state)))))

;;; ════════════════ 插件描述符 ════════════════

(define (demo-plugin)
  (make-plugin
   'demo
   #:env (make-environment
          #:commands demo-commands
          #:rules (list (make-rule 'always demo-keys)))
   #:status-parts (list demo-status-part)
   #:state-init (λ (s) (plugin-state-set s 'demo 0))))

;;; ════════════════ 装配：editor + status 槽，装一个插件 ════════════════

(define (plugin-demo)
  (define did (doc-id 1))
  (define vid (view-id 1))
  (define editor-rid (region-id 1))
  (define chrome-rid (region-id 2))

  (define engine (make-engine))
  (void (engine-create-doc! engine did "plugin.rkt"
                            (string-join
                             '("This demo's whole \"plugin system\" is env/plugin.rkt."
                               ""
                               "The plugin contributes: a command (demo-hi), a key (h), a store slot,"
                               "and one status-bar part (hi×N). No framework file mentions it."
                               ""
                               "Press h a few times.")
                             "\n")))
  (void (engine-create-view! engine vid did))

  (define baseline (engine-view-doc-version (make-engine-view engine) did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "plugin.rkt"
                                                       #:path "plugin.rkt"
                                                       #:saved-version baseline))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws editor-rid
                                     (region editor-rid (list (view-member vid)) vid 'editor))])
      ws))

  (define state0 (make-state #:workspace ws #:ids (make-id-counter 2 2 3 1)))
  (define s1 (install-chrome! engine state0 chrome-rid))

  (define layout*
    (make-split 'tb
                (list (make-leaf editor-rid (flex 1))
                      (make-leaf chrome-rid (fixed 1) #:borders '()))
                (flex 1)))

  (define s2 (state-set-workspace s1
                                  (struct-copy workspace (state-workspace s1)
                                               [layout layout*])))
  (define s3 (state-set-focus (state-chrome* s2 (λ (c) (chrome-set-message c "press h")))
                              vid))

  ;; 装配：env 与 state 一起进（plugins-apply 是纯的）。
  (define-values (env state)
    (plugins-apply default-env s3 (list (demo-plugin))))
  (values env state engine))

(module+ main
  (define-values (env state engine) (plugin-demo))
  (run-app env state engine))
