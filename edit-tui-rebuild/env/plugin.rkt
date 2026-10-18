#lang racket

;;; layer  : env
;;; effect : 无（纯值 + 纯 fold）

;;; env/plugin.rkt —— 插件描述符 + 纯装配（env 层，纯值/纯函数）
;;;
;;; 插件 = 一份数据，不是 require 顺序：
;;;
;;;   (struct plugin (id env status-parts panels hooks state-init))
;;;     id           : symbol                     插件命名空间（store 的键）
;;;     env          : environment                贡献（roles/modes/commands/keymaps/
;;;                                               rules/scopes/doc-types/input-commands）
;;;     status-parts : (listof status-part)       追加的状态栏段（**加法**语义）
;;;     panels       : (listof panel-spec)        自带面板（每帧同步自动挂上）
;;;     hooks        : (listof hook)              信号 -> 旁观者逻辑（语法高亮/补全/文档都挂这里）
;;;     state-init   : (state -> state) | #f       写自己的 store 槽
;;;
;;;   (struct panel-spec (name role mode sync))
;;;     面板身份 = 名字 / role / mode / 每帧同步；安装还需要 region-id 与
;;;     layout 位置，那是宿主的策略，所以 install 不在 spec 里。
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
;;; 先 merge env，再追加状态栏段 / 面板 sync / hook，最后跑 state-init。
;;; 副作用（建 engine 对象 / 装面板）不在这里：
;;;   安装是 effects/panel.rkt 的 panel-install! / panel-spec-install!，
;;;   而“哪些插件算内置”是 plugins/builtin.rkt。
;;;
;;; 暂定：还没有 plugin-disable / reload —— 那需要记“哪条贡献来自哪个插件”
;;; （environment 目前是无来源的纯值）。先只支持“启动时装配一次”。

(provide (struct-out panel-spec)
         make-panel-spec
         (struct-out plugin)
         make-plugin
         plugin?
         plugins-env
         plugins-apply)

(require "../model/state.rkt"
         "../base/status-part.rkt"
         "environment.rkt"
         "hook.rkt")

;;; ════════════════ 面板描述 ════════════════

(struct panel-spec (name role mode sync) #:transparent)
;; name : string     document 名（资源列表 / 调试里可见）
;; role : symbol     区域角色（splittable? / close-policy / focusable? / target?）
;; mode : symbol     document mode（决定面板内键表）
;; sync : (state engine -> any)  每帧渲染前的同步（挂到 env.panel-syncs）

(define (make-panel-spec #:name [name "*panel*"]
                         #:role [role 'panel]
                         #:mode [mode 'text]
                         #:sync [sync #f])
  (unless (string? name) (error 'make-panel-spec "name 要是 string：~a" name))
  (unless (symbol? role) (error 'make-panel-spec "role 要是 symbol：~a" role))
  (unless (symbol? mode) (error 'make-panel-spec "mode 要是 symbol：~a" mode))
  (unless (or (not sync) (procedure? sync))
    (error 'make-panel-spec "sync 要是过程或 #f：~a" sync))
  (panel-spec name role mode sync))

;;; ════════════════ 插件 ════════════════

(struct plugin (id env status-parts panels hooks state-init) #:transparent)

(define (make-plugin id
                     #:env [env (environment-empty)]
                     #:status-parts [status-parts '()]
                     #:panels [panels '()]
                     #:hooks [hooks '()]
                     #:state-init [state-init #f])
  (unless (symbol? id) (error 'make-plugin "plugin id 要是 symbol：~a" id))
  (unless (environment? env) (error 'make-plugin "env 要是 environment：~a" env))
  (for ([p (in-list status-parts)])
    (unless (status-part? p) (error 'make-plugin "status-parts 里要 status-part：~a" p)))
  (for ([p (in-list panels)])
    (unless (panel-spec? p) (error 'make-plugin "panels 里要 panel-spec：~a" p)))
  (for ([h (in-list hooks)])
    (unless (hook? h) (error 'make-plugin "hooks 里要 hook：~a" h)))
  (unless (or (not state-init) (procedure? state-init))
    (error 'make-plugin "state-init 要是过程或 #f：~a" state-init))
  (plugin id env status-parts panels hooks state-init))

;; 单个插件的 env 贡献：merge + 状态栏追加 + 面板 sync 追加。
(define (plugin-env-apply env p)
  (define env1 (environment-merge env (plugin-env p)))
  (define env2 (environment-add-status-parts env1 (plugin-status-parts p)))
  (environment-add-hooks
   (environment-add-panel-syncs env2
                                (for/list ([spec (in-list (plugin-panels p))]
                                           #:when (panel-spec-sync spec))
                                  (panel-spec-sync spec)))
   (plugin-hooks p)))

(define (plugins-env env plugins)
  (for/fold ([env env]) ([p (in-list plugins)])
    (plugin-env-apply env p)))

;; 纯装配：env 与 state 一起推进（state-init 依次执行）。
(define (plugins-apply env state plugins)
  (for/fold ([env env] [state state]) ([p (in-list plugins)])
    (define f (plugin-state-init p))
    (values (plugin-env-apply env p)
            (if f (f state) state))))
