#lang racket

;;; env/environment.rkt —— 装配期只读环境（纯值）
;;; layer  : env
;;; effect : 无（纯值 + 纯合并）

;;; Environment 把“行为策略”集中成一个值，而不是模块级全局表：
;;;
;;;   roles    : role-id    -> role
;;;   modes    : mode-id    -> mode
;;;   scopes   : scope-id   -> scope
;;;   commands : command-id -> command
;;;   keymaps  : name       -> keymap
;;;   panel-syncs : (listof (state engine -> any))   每帧渲染前要跑的面板同步
;;;   hooks    : (listof hook)               信号 -> 旁观者逻辑（按 point + priority 跑）
;;;   face-layers : (listof symbol)          face 层序（先低后高；后层非 #f 分量覆盖前层）
;;;
;;; 好处：
;;;   · 多个 app 实例可以有不同的 env；
;;;   · 测试只构造需要的那几项；
;;;   · 插件贡献 = 往 env 里合并数据，而不是 require 时 set!。
;;;
;;; 查不到时给保守默认（role-default / mode-default / 空 keymap / #f）。

(provide (struct-out environment)
         make-environment
         environment-empty
         environment-role
         environment-mode
         environment-command
         environment-keymap
         environment-mode-keymaps
         environment-add-role
         environment-add-mode
         environment-add-scope
         environment-add-command
         environment-add-keymap
         environment-add-rule
         environment-add-status-part
         environment-add-status-parts
         environment-add-doc-type
         environment-doc-type
         environment-doc-type-for-path
         environment-input-commands
         environment-add-input-command
         environment-panel-syncs
         environment-add-panel-sync
         environment-add-panel-syncs
         environment-face-layers
         environment-add-face-layer
         environment-add-face-layers
         environment-hooks
         environment-add-hook
         environment-add-hooks
         environment-decors
         environment-add-decor
         environment-add-decors
         environment-contributions
         environment-base
         environment-interactions
         environment-interaction
         environment-add-interaction
         environment-services
         environment-service
         environment-service-kinds
         environment-add-service
         environment-continuations
         environment-continuation
         environment-add-continuation
         environment-merge)

(require "../base/keymap.rkt"
         "../base/transition.rkt"
         "role.rkt"
         "mode.rkt"
         "scope.rkt"
         "command.rkt"
         "rule.rkt"
         "doc-type.rkt"
         "input-command.rkt"
         "hook.rkt"
         "service.rkt"
         "../base/status-part.rkt"
         "../model/face-decor.rkt")

(struct environment (roles modes scopes commands keymaps rules status doc-types input-commands panel-syncs hooks face-layers decors contributions base interactions services continuations) #:transparent)
;; roles    : (hash/c symbol role)
;; modes    : (hash/c symbol mode)
;; scopes   : (hash/c symbol scope)
;; commands : (hash/c symbol command)
;; keymaps  : (hash/c symbol keymap)
;; rules    : (listof rule)               带 scope 的额外表（高 -> 低）
;; status   : #f | (listof status-part)   #f = 用投影默认段
;; doc-types: (hash/c symbol doc-type)    打开文件时按路径匹配
;; input-commands: (listof input-command) 输入栏字符串匹配（高 -> 低）
;; hooks    : (listof hook)               信号点 -> 旁观者逻辑（按 priority 降序）
;; face-layers : (listof symbol)          face 层序（先低后高）
;; decors   : (listof face-decor)         增量 face 装饰（按文档 applies? 过滤后挂到 engine）
;; panel-syncs: (listof procedure)        每帧渲染前调用 (state engine -> any)；
;;             面板由插件贡献时挂在这里，runtime 只负责遍历，不认识具体面板。
;; contributions: (listof contribution)  带 owner 的贡献清单（env/extension.rkt）。
;;             编译后的字段仍是上面这些；contributions 只用于 provenance / 校验 / uninstall。
;; base     : environment | #f            第一次加 contribution 前的快照；
;;             environment-remove-owner 从它重建（#f = 没有可重建的 base）。
;; interactions : (hash/c symbol procedure)  interaction kind -> cancel(ctx, data)；
;;             栈条目只存 kind + data，取消函数在 env 里。
;; services : (hash/c symbol service-spec)   worker service 能力声明。
;; continuations : (hash/c symbol procedure)  effect data continuation 的 tag -> handler；
;;                 handler : (state data . results -> transition)。

(define (environment-empty)
  (environment (hash) (hash) (hash) (hash) (hash) '() #f (hash) '() '() '() '() '() '() #f (hash) (hash) (hash)))

(define (make-environment #:roles [roles (hash)]
                          #:modes [modes (hash)]
                          #:scopes [scopes (hash)]
                          #:commands [commands (hash)]
                          #:keymaps [keymaps (hash)]
                          #:rules [rules '()]
                          #:status [status #f]
                          #:doc-types [doc-types (hash)]
                          #:input-commands [input-commands '()]
                          #:panel-syncs [panel-syncs '()]
                          #:hooks [hooks '()]
                          #:face-layers [face-layers '()]
                          #:decors [decors '()]
                          #:contributions [contributions '()]
                          #:base [base #f]
                          #:interactions [interactions (hash)]
                          #:services [services (hash)]
                          #:continuations [continuations (hash)])
  (environment roles modes scopes commands keymaps rules status
               doc-types input-commands panel-syncs hooks face-layers decors
               contributions base interactions services continuations))

;;; ---------- 查 ----------

(define (environment-role env id)
  (hash-ref (environment-roles env) id role-default))

(define (environment-mode env id)
  (hash-ref (environment-modes env) id mode-default))

(define (environment-command env id)
  (hash-ref (environment-commands env) id #f))

(define (environment-keymap env name)
  (hash-ref (environment-keymaps env) name empty-keymap))

(define (environment-doc-type env name)
  (hash-ref (environment-doc-types env) name #f))

(define (environment-doc-type-for-path env path)
  (for/first ([dt (in-hash-values (environment-doc-types env))]
              #:when (doc-type-matches-path? dt path))
    dt))


(define (environment-mode-keymaps env id)
  (mode-keymaps (environment-mode env id)))

;;; ---------- 纯增 / 合并 ----------

(define (environment-add-role env id r)
  (unless (symbol? id) (error 'environment-add-role "role id 要是 symbol：~a" id))
  (struct-copy environment env [roles (hash-set (environment-roles env) id r)]))

(define (environment-add-mode env id m)
  (unless (symbol? id) (error 'environment-add-mode "mode id 要是 symbol：~a" id))
  (struct-copy environment env [modes (hash-set (environment-modes env) id m)]))

(define (environment-add-scope env id s)
  (unless (symbol? id) (error 'environment-add-scope "scope id 要是 symbol：~a" id))
  (struct-copy environment env [scopes (hash-set (environment-scopes env) id s)]))

(define (environment-add-command env id c)
  (unless (symbol? id) (error 'environment-add-command "command id 要是 symbol：~a" id))
  (unless (command? c) (error 'environment-add-command "command 要是 command：~a" c))
  (struct-copy environment env [commands (hash-set (environment-commands env) id c)]))

(define (environment-add-keymap env name km)
  (unless (symbol? name) (error 'environment-add-keymap "keymap 名要是 symbol：~a" name))
  (unless (keymap? km) (error 'environment-add-keymap "要是 keymap：~a" km))
  (struct-copy environment env [keymaps (hash-set (environment-keymaps env) name km)]))

;; 新规则放最前（优先）。
(define (environment-add-rule env r)
  (struct-copy environment env [rules (cons r (environment-rules env))]))
;; 状态栏段：新段放最前。传入 #f 表示恢复默认段。
(define (environment-add-status-part env part)
  (environment-add-status-parts env (list part)))

;; 批量加段（插件贡献用）：一个都没有 = 不动 status。
(define (environment-add-status-parts env parts)
  (if (null? parts)
      env
      (struct-copy environment env
                   [status (append parts (or (environment-status env) '()))])))

(define (environment-add-doc-type env dt)
  (struct-copy environment env
               [doc-types (hash-set (environment-doc-types env) (doc-type-name dt) dt)]))

(define (environment-add-input-command env c)
  (struct-copy environment env [input-commands (cons c (environment-input-commands env))]))

;; 面板每帧同步：新同步器排在被注册的顺序（与 require/装配顺序一致）。
(define (environment-add-panel-sync env f)
  (unless (procedure? f) (error 'environment-add-panel-sync "要过程：~a" f))
  (struct-copy environment env
               [panel-syncs (append (environment-panel-syncs env) (list f))]))

(define (environment-add-panel-syncs env fs)
  (for/fold ([e env]) ([f (in-list fs)]) (environment-add-panel-sync e f)))

;; 钩子：append（同一 point 按 priority 排序是运行时的事）。
(define (environment-add-hook env h)
  (unless (hook? h) (error 'environment-add-hook "要 hook：~a" h))
  (struct-copy environment env [hooks (append (environment-hooks env) (list h))]))

(define (environment-add-hooks env hs)
  (for/fold ([e env]) ([h (in-list hs)]) (environment-add-hook e h)))

;; face 层：**追加**（越靠后越在上面）。
(define (environment-add-face-layer env l)
  (unless (symbol? l) (error 'environment-add-face-layer "层名要是 symbol：~a" l))
  (struct-copy environment env [face-layers (append (environment-face-layers env) (list l))]))

(define (environment-add-face-layers env ls)
  (for/fold ([e env]) ([l (in-list ls)]) (environment-add-face-layer e l)))

;; 增量 face decor：append（同一文档按注册顺序跑 change）。
(define (environment-add-decor env d)
  (unless (face-decor? d) (error 'environment-add-decor "要 face-decor：~a" d))
  (struct-copy environment env [decors (append (environment-decors env) (list d))]))

(define (environment-add-interaction env kind handler)
  (unless (symbol? kind) (error 'environment-add-interaction "kind 要是 symbol：~a" kind))
  (unless (procedure? handler) (error 'environment-add-interaction "handler 要是过程：~a" handler))
  (struct-copy environment env
               [interactions (hash-set (environment-interactions env) kind handler)]))

(define (environment-interaction env kind)
  (hash-ref (environment-interactions env) kind #f))

(define (environment-service env kind)
  (hash-ref (environment-services env) kind #f))
(define (environment-service-kinds env)
  (sort (hash-keys (environment-services env)) symbol<?))

(define (environment-add-service env spec)
  (unless (service-spec? spec)
    (error 'environment-add-service "要 service-spec：~a" spec))
  (struct-copy environment env
               [services (hash-set (environment-services env)
                                   (service-spec-kind spec) spec)]))

(define (environment-continuation env tag)
  (hash-ref (environment-continuations env) tag #f))

(define (environment-add-continuation env tag handler)
  (unless (symbol? tag)
    (error 'environment-add-continuation "tag 要是 symbol：~a" tag))
  (unless (procedure? handler)
    (error 'environment-add-continuation "handler 要是过程：~a" handler))
  (struct-copy environment env
               [continuations (hash-set (environment-continuations env) tag handler)]))

(define (environment-add-decors env ds)
  (for/fold ([e env]) ([d (in-list ds)]) (environment-add-decor e d)))

;; 覆盖式合并：b 的同名项覆盖 a。插件 / 用户配置用这个。
(define (environment-merge a b)
  (define (overlay ka kb)
    (for/fold ([h ka]) ([(k v) (in-hash kb)]) (hash-set h k v)))
  (environment (overlay (environment-roles a)    (environment-roles b))
               (overlay (environment-modes a)    (environment-modes b))
               (overlay (environment-scopes a)   (environment-scopes b))
               (overlay (environment-commands a) (environment-commands b))
               (overlay (environment-keymaps a)  (environment-keymaps b))
               ;; b 的规则在前 = 后合并的 env 优先
               (append (environment-rules b) (environment-rules a))
               (or (environment-status b) (environment-status a))
               (overlay (environment-doc-types a) (environment-doc-types b))
               (append (environment-input-commands b) (environment-input-commands a))
               ;; 同步器 / 钩子不重名、不去重：a 的在先，b 的在后
               (append (environment-panel-syncs a) (environment-panel-syncs b))
               (append (environment-hooks a) (environment-hooks b))
               (append (environment-face-layers a) (environment-face-layers b))
               (append (environment-decors a) (environment-decors b))
               (append (environment-contributions a) (environment-contributions b))
               ;; base 只保留一侧的快照；真正的“可重建”由 plugin-env-apply 显式设置。
               (or (environment-base a) (environment-base b))
               (overlay (environment-interactions a) (environment-interactions b))
               (overlay (environment-services a) (environment-services b))
               (overlay (environment-continuations a) (environment-continuations b))))
