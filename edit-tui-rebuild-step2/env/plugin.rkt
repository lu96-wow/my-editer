#lang racket

;;; layer  : env
;;; effect : 无（纯值 + 纯 fold）

;;; env/plugin.rkt —— 插件描述符 + 纯装配（env 层，纯值/纯函数）
;;;
;;; 插件 = 一份数据，不是 require 顺序：
;;;
;;;   (struct plugin (id env status-parts panels hooks decors state-init contributions))
;;;     id            : symbol                     插件命名空间（store 的键）
;;;     env           : environment                env 贡献（底层仍是 add-* 表）
;;;     status-parts  : (listof status-part)       追加的状态栏段（**加法**语义）
;;;     panels        : (listof panel-spec)        自带面板（每帧同步自动挂上）
;;;     hooks         : (listof hook)              信号 -> 旁观者逻辑
;;;     decors        : (listof face-decor)        每文档增量 face
;;;     state-init    : (state -> state) | #f      写自己的 store 槽
;;;     contributions : (listof contribution)      统一贡献清单（owner = id）
;;;
;;;   panel-spec 在 env/panel-spec.rkt；这里 re-export，保持旧 API 不变。
;;;   推荐新插件用 #:contributions；旧字段仍然兼容，并会在装配时转成 contribution。
;;;
;;; 为什么 status-parts 不放进 env：
;;;   environment-merge 是“覆盖”语义（b 的同名项覆盖 a，含 status）；
;;;   插件通常想“再加一段”而不是“换掉整条状态栏”，所以显式分开，避免歧义。
;;;
;;; 为什么全局键用 env.rules 而不是 env.keymaps['global]：
;;;   keymaps 也按名字覆盖，插件写 'global 会把框架的全局键表整个换掉。
;;;   `(make-rule 'always keys)` 是加一层，优先级在 mode 之上、global 之下（见 dispatch/rules.rkt）。
;;;
;;; 装配是纯 fold：
;;;
;;;   (plugins-env   env plugins)         -> env'
;;;   (plugins-apply env state plugins)   -> (values env' state')
;;;
;;; 先 merge env，再把旧字段 / #:contributions 统一落到现有 env 字段，最后跑 state-init。
;;; 副作用（建 engine 对象 / 装面板）不在这里：
;;;   安装是 effects/panel.rkt 的 panel-install! / panel-spec-install!，
;;;   而“哪些插件算内置”是 plugins/builtin.rkt。
;;;
;;; 贡献现在带 owner（environment.contributions），并提供装配期校验。
;;; disable / reload / uninstall 还没有接线，但 provenance 已经就位。

(provide (all-from-out "panel-spec.rkt")
         (struct-out plugin)
         make-plugin
         plugin?
         plugins-env
         plugins-apply)

(require "../model/state.rkt"
         "../model/face-decor.rkt"
         "../base/status-part.rkt"
         "environment.rkt"
         "panel-spec.rkt"
         "hook.rkt"
         "extension.rkt")

;;; ════════════════ 插件 ════════════════

(struct plugin (id env status-parts panels hooks decors state-init contributions) #:transparent)

(define (make-plugin id
                     #:env [env (environment-empty)]
                     #:status-parts [status-parts '()]
                     #:panels [panels '()]
                     #:hooks [hooks '()]
                     #:decors [decors '()]
                     #:state-init [state-init #f]
                     #:contributions [contributions '()])
  (unless (symbol? id) (error 'make-plugin "plugin id 要是 symbol：~a" id))
  (unless (environment? env) (error 'make-plugin "env 要是 environment：~a" env))
  (for ([p (in-list status-parts)])
    (unless (status-part? p) (error 'make-plugin "status-parts 里要 status-part：~a" p)))
  (for ([p (in-list panels)])
    (unless (panel-spec? p) (error 'make-plugin "panels 里要 panel-spec：~a" p)))
  (for ([h (in-list hooks)])
    (unless (hook? h) (error 'make-plugin "hooks 里要 hook：~a" h)))
  (for ([d (in-list decors)])
    (unless (face-decor? d) (error 'make-plugin "decors 里要 face-decor：~a" d)))
  (unless (or (not state-init) (procedure? state-init))
    (error 'make-plugin "state-init 要是过程或 #f：~a" state-init))
  (for ([c (in-list contributions)])
    (unless (contribution? c)
      (error 'make-plugin "contributions 里要 contribution：~a" c))
    (unless (eq? (contribution-owner c) id)
      (error 'make-plugin "contribution owner 必须是插件 id ~a：~a" id c)))
  (plugin id env status-parts panels hooks decors state-init contributions))

;; 单个插件的 env 贡献：统一走 contribution（owner = plugin id）。
;;
;; plugin 的旧字段仍然保留，但在这里都变成 contribution：
;;   env          -> merge（env 自己携带的 contributions 一并保留）
;;   status-parts -> 'status-parts（一次加，保持顺序）
;;   panels       -> 'panel（自动挂 sync）
;;   hooks        -> 'hook
;;   decors       -> 'decor
;;
;; 这样 environment.contributions 里有完整的来源清单，校验 / 未来 uninstall 都从这里读。
(define (plugin-env-apply env p)
  (define id (plugin-id p))
  ;; 第一次加插件贡献前的快照：environment-remove-owner 从这里重建。
  (define base (or (environment-base env)
                   (environment-strip-contributions env)))
  ;; plugin.env 的字段全部归 owner = id；先 strip，避免把 env 自带的
  ;; contributions 重复展开。字段本身仍用 environment-merge 合并（保留覆盖 /
  ;; 规则顺序语义），贡献清单只 attach、不重编译。
  (define pe (plugin-env p))
  (define pe* (environment-strip-contributions pe))
  (define env1 (environment-merge env pe*))
  (define env2 (struct-copy environment env1 [base base]))
  (define env3
    (environment-attach-contributions
     env2 (environment->contributions pe* id)))
  (define (add e kind payload)
    (environment-add-contribution e (make-contribution id kind payload)))
  (define env4
    (if (null? (plugin-status-parts p))
        env3
        (add env3 'status-parts (plugin-status-parts p))))
  (define env5
    (for/fold ([e env4]) ([spec (in-list (plugin-panels p))])
      (add e 'panel spec)))
  (define env6
    (for/fold ([e env5]) ([h (in-list (plugin-hooks p))])
      (add e 'hook h)))
  (define env7
    (for/fold ([e env6]) ([d (in-list (plugin-decors p))])
      (add e 'decor d)))
  ;; 显式 contribution 已经带 owner；直接落到现有 env 字段。
  (environment-add-contributions env7 (plugin-contributions p)))

(define (plugins-env env plugins)
  (validate-environment!
   (for/fold ([env env]) ([p (in-list plugins)])
     (plugin-env-apply env p))))

;; 纯装配：env 与 state 一起推进（state-init 依次执行）。
(define (plugins-apply env state plugins)
  (define-values (env* state*)
    (for/fold ([env env] [state state]) ([p (in-list plugins)])
      (define f (plugin-state-init p))
      (values (plugin-env-apply env p)
              (if f (f state) state))))
  (values (validate-environment! env*) state*))
