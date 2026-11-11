#lang racket

;;; edit-tui-rebuild/editor/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 registry / discovery，只是一个普通值：
;;;   id       插件命名空间（plugin-states 的 key）
;;;   state    插件自己的初始纯状态
;;;   hooks    注册到扩展点的 handler 列表
;;;   commands 可选：宿主安装的命令表片段（第一阶段先留 #f）
;;;
;;; 插件只 require editor/api.rkt；不直接 require engine / hooks 实现。
;;; 这里为了让插件定义 hook，允许 require editor/hooks.rkt 的公开构造器。

(require "../core/command/api.rkt"
         "hooks.rkt"
         "context.rkt"
         "state.rkt")

(provide (struct-out plugin)
         make-plugin
         (struct-out guarded-command)
         make-guarded-command
         plugins->hooks
         plugins->states
         plugins->command-table
         plugins->command-tables
         run-plugin-syncs)

(struct plugin
  (id state hooks commands sync)
  #:transparent)

;; 条件命令：when-fn 不成立时，host 继续查下一张命令表。
;; 这样插件可以贡献 Enter / C-r，而不抢 editor 的 Enter。
(struct guarded-command
  (when-fn run)
  #:transparent)

(define (make-guarded-command #:when when-fn #:run run)
  (guarded-command when-fn run))

(define (make-plugin #:id id
                     #:state [state #f]
                     #:hooks [hooks '()]
                     #:commands [commands #f]
                     #:sync [sync #f])
  (unless (symbol? id)
    (raise-argument-error 'make-plugin "symbol?" id))
  (when (and sync (not (procedure? sync)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" sync))
  (plugin id state hooks commands sync))

;; 汇总所有插件的 hooks；宿主用 make-hook-registry 建 registry。
(define (plugins->hooks plugins)
  (append* (for/list ([p (in-list plugins)]) (plugin-hooks p))))

;; 汇总初始 plugin-states。
(define (plugins->states plugins)
  (for/fold ([h (hash)]) ([p (in-list plugins)])
    (hash-set h (plugin-id p) (plugin-state p))))

;; 汇总插件命令表；先安装的插件优先。
(define (plugins->command-table plugins)
  (apply command-table-merge (plugins->command-tables plugins)))

;; host 用列表逐张查，guarded-command 不成立时继续下一张。
(define (plugins->command-tables plugins)
  (for/list ([p (in-list plugins)]
             #:when (command-table? (plugin-commands p)))
    (plugin-commands p)))

;; 每帧同步阶段：按插件安装顺序显式执行。
;; sync : (editor state -> state')
(define (run-plugin-syncs ed state)
  (for/fold ([s state]) ([p (in-list (editor-plugins ed))])
    (define f (plugin-sync p))
    (if f (f ed s) s)))
