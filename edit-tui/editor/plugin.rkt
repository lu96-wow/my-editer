#lang racket

;;; edit-tui-rebuild/editor/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 registry / discovery，只是一个普通值：
;;;   id       插件命名空间（plugin-states 的 key）
;;;   state    插件自己的初始纯状态
;;;   hooks    注册到扩展点的 handler 列表
;;;   commands 可选：一张 command-table，或 listof command-group（多 scope）
;;;   command-scope 单张 command-table 的 scope（默认 'global）
;;;
;;; 插件只 require editor/api.rkt；不直接 require engine / hooks 实现。
;;; 这里为了让插件定义 hook，允许 require editor/hooks.rkt 的公开构造器。

(require "../core/command/api.rkt"
         "../core/job/api.rkt"
         "hooks.rkt"
         "contributions.rkt")

(provide (struct-out plugin)
         make-plugin
         (struct-out guarded-command)
         make-guarded-command
         (struct-out command-binding)
         (struct-out command-group)
         plugins->hooks
         plugins->states
         plugins->contributions)

(struct plugin
  (id state hooks commands command-scope
      sync services handle-job handle-timer key-owner overlays)
  #:transparent)

;; 条件命令：when-fn 不成立时，host 继续查下一张命令表。
;; 这样插件可以贡献 Enter / C-r，而不抢 editor 的 Enter。
;; when-fn / run 都拿 (ed state ps)，ps 只属于命令的 owner。
(struct guarded-command
  (when-fn run)
  #:transparent)

;; 一条命令绑定。contribution registry 存 (owner, binding)；
;; host 再从这些 binding 建 command-table（leaf 是 ordered owner/command 列表）。
(struct command-binding
  (keys value)
  #:transparent)

;; 同一插件需要多个 scope 时使用；单表插件仍可直接给 #:commands。
(struct command-group
  (scope table)
  #:transparent)

(define (command-table-or-groups? x)
  (or (command-table? x)
      (and (list? x) (andmap command-group? x))))

(define (plugin-command-groups p)
  (define c (plugin-commands p))
  (cond
    [(command-table? c) (list (command-group (plugin-command-scope p) c))]
    [(list? c) c]
    [else '()]))

(define (make-guarded-command #:when when-fn #:run run)
  (guarded-command when-fn run))

(define (make-plugin #:id id
                     #:state [state #f]
                     #:hooks [hooks '()]
                     #:commands [commands #f]
                     #:command-scope [command-scope 'global]
                     #:sync [sync #f]
                     #:services [services '()]
                     #:handle-job [handle-job #f]
                     #:handle-timer [handle-timer #f]
                     #:key-owner [key-owner #f]
                     #:overlays [overlays #f])
  (unless (symbol? id)
    (raise-argument-error 'make-plugin "symbol?" id))
  (unless (symbol? command-scope)
    (raise-argument-error 'make-plugin "symbol?" command-scope))
  (when (and commands (not (command-table-or-groups? commands)))
    (raise-argument-error 'make-plugin
                          "(or/c #f command-table? (listof command-group?))"
                          commands))
  (when (and sync (not (procedure? sync)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" sync))
  (when (and handle-job (not (procedure? handle-job)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" handle-job))
  (when (and handle-timer (not (procedure? handle-timer)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" handle-timer))
  (when (and key-owner (not (procedure? key-owner)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" key-owner))
  (when (and overlays (not (procedure? overlays)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" overlays))
  ;; hook owner 必须等于插件 id，插件不能借别人的 plugin-state 注册 hook。
  (for ([h (in-list hooks)])
    (unless (eq? (hook-owner h) id)
      (error 'make-plugin "hook owner ~a 必须等于 plugin id ~a"
             (hook-owner h) id)))
  (plugin id state hooks commands command-scope
          sync services handle-job handle-timer key-owner overlays))

;; 汇总所有插件的 hooks；宿主用 make-hook-registry 建 registry。
(define (plugins->hooks plugins)
  (append* (for/list ([p (in-list plugins)]) (plugin-hooks p))))

;; 汇总初始 plugin-states。
(define (plugins->states plugins)
  (for/fold ([h (hash)]) ([p (in-list plugins)])
    (hash-set h (plugin-id p) (plugin-state p))))

;; 把插件字段翻译成统一 contribution registry。
(define (plugins->contributions plugins)
  (append*
   (for/list ([p (in-list plugins)])
     (define id (plugin-id p))
     (append
      (if (plugin-sync p)
          (list (contribution point/frame-sync #f id 0 0 (plugin-sync p)))
          '())
      (if (plugin-overlays p)
          (list (contribution point/frame-overlay #f id 0 0 (plugin-overlays p)))
          '())
      (if (plugin-handle-timer p)
          (list (contribution point/timer #f id 0 0 (plugin-handle-timer p)))
          '())
      (if (plugin-key-owner p)
          (list (contribution point/key-owner #f id 0 0 (plugin-key-owner p)))
          '())
      (append*
       (for/list ([g (in-list (plugin-command-groups p))])
         (for/list ([b (in-list (command-table-bindings (command-group-table g)))])
           (contribution point/command (command-group-scope g) id 0 0
                         (command-binding (car b) (cadr b))))))
      (append*
       (for/list ([svc (in-list (plugin-services p))])
         (define kind (service-name svc))
         (append
          (list (contribution point/job-service kind id 0 0 (service-handler svc)))
          (if (plugin-handle-job p)
              (list (contribution point/job-result kind id 0 0 (plugin-handle-job p)))
              '()))))))))
