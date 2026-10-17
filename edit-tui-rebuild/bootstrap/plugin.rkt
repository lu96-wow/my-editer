#lang racket

;;; bootstrap/plugin.rkt —— 插件描述符 + 纯装配（装配层，本身是纯函数）
;;;
;;; 插件 = 一份数据，不是 require 顺序：
;;;
;;;   (struct plugin (id env status-parts state-init))
;;;     id           : symbol                     插件命名空间（store 的键）
;;;     env          : environment                贡献（roles/modes/commands/keymaps/
;;;                                               rules/scopes/doc-types/handlers/panel-syncs）
;;;     status-parts : (listof status-part)       追加的状态栏段（**加法**语义）
;;;     state-init   : (state -> state) | #f       写自己的 store 槽
;;;
;;; 为什么 status-parts 不放进 env：
;;;   environment-merge 是“覆盖”语义（b 的同名项覆盖 a，含 status）；
;;;   插件通常想“再加一段”而不是“换掉整条状态栏”，所以显式分开，避免歧义。
;;;
;;; 装配是纯 fold：
;;;
;;;   (plugins-apply env state plugins) -> (values env' state')
;;;
;;; 先 merge env（后者优先），再追加状态栏段，再跑 state-init。
;;; 副作用（建 engine 对象 / 装面板）不在这里：那是 bootstrap 的装配动作
;;; （见 bootstrap/panel.rkt），插件只声明参数。
;;;
;;; 暂定：还没有 plugin-disable / reload —— 那需要记“哪条贡献来自哪个插件”
;;; （environment 目前是无来源的纯值）。先只支持“启动时装配一次”。

(provide (struct-out plugin)
         make-plugin
         plugin?
         plugins-apply)

(require "../model/state.rkt"
         "../env/environment.rkt"
         "../base/status.rkt")

(struct plugin (id env status-parts state-init) #:transparent)
;; id           : symbol
;; env          : environment
;; status-parts : (listof status-part)
;; state-init   : #f | (state -> state)

(define (make-plugin id
                     #:env [env (environment-empty)]
                     #:status-parts [status-parts '()]
                     #:state-init [state-init #f])
  (unless (symbol? id) (error 'make-plugin "plugin id 要是 symbol：~a" id))
  (unless (environment? env) (error 'make-plugin "env 要是 environment：~a" env))
  (for ([p (in-list status-parts)])
    (unless (status-part? p) (error 'make-plugin "status-parts 里要 status-part：~a" p)))
  (unless (or (not state-init) (procedure? state-init))
    (error 'make-plugin "state-init 要是过程或 #f：~a" state-init))
  (plugin id env status-parts state-init))

;; 纯装配：env 合并 + 状态栏追加 + state-init。
;; 重复 id 不做特殊处理（后一个的贡献覆盖同名项，state-init 依次执行）。
(define (plugins-apply env state plugins)
  (for/fold ([env env] [state state]) ([p (in-list plugins)])
    (define env*
      (environment-add-status-parts
       (environment-merge env (plugin-env p))
       (plugin-status-parts p)))
    (define f (plugin-state-init p))
    (values env* (if f (f state) state))))
