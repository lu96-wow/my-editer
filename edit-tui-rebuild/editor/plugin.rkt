#lang racket

;;; edit-tui-rebuild/editor/plugin.rkt —— 最小插件值
;;;
;;; 插件不是 registry / discovery，只是一个普通值：
;;;   id       插件命名空间（plugin-states 的 key）
;;;   state    插件自己的初始纯状态
;;;   hooks    注册到扩展点的 handler 列表
;;;   commands 可选：宿主安装的命令表片段；命令只拿自己的 plugin-state
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
         (struct-out owned-command-table)
         plugins->hooks
         plugins->states
         plugins->command-table
         plugins->command-tables
         plugins->contributions)

(struct plugin
  (id state hooks commands sync services handle-job handle-timer overlays)
  #:transparent)

;; 条件命令：when-fn 不成立时，host 继续查下一张命令表。
;; 这样插件可以贡献 Enter / C-r，而不抢 editor 的 Enter。
;; when-fn / run 都拿 (ed state ps)，ps 只属于命令的 owner。
(struct guarded-command
  (when-fn run)
  #:transparent)

;; 带 owner 的命令表。host 查表时一起拿到 owner，执行后再按 owner 写 ps。
(struct owned-command-table
  (owner table)
  #:transparent)

(define (make-guarded-command #:when when-fn #:run run)
  (guarded-command when-fn run))

(define (make-plugin #:id id
                     #:state [state #f]
                     #:hooks [hooks '()]
                     #:commands [commands #f]
                     #:sync [sync #f]
                     #:services [services '()]
                     #:handle-job [handle-job #f]
                     #:handle-timer [handle-timer #f]
                     #:overlays [overlays #f])
  (unless (symbol? id)
    (raise-argument-error 'make-plugin "symbol?" id))
  (when (and sync (not (procedure? sync)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" sync))
  (when (and handle-job (not (procedure? handle-job)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" handle-job))
  (when (and handle-timer (not (procedure? handle-timer)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" handle-timer))
  (when (and overlays (not (procedure? overlays)))
    (raise-argument-error 'make-plugin "(or/c #f procedure?)" overlays))
  ;; hook owner 必须等于插件 id，插件不能借别人的 plugin-state 注册 hook。
  (for ([h (in-list hooks)])
    (unless (eq? (hook-owner h) id)
      (error 'make-plugin "hook owner ~a 必须等于 plugin id ~a"
             (hook-owner h) id)))
  (plugin id state hooks commands sync services handle-job handle-timer overlays))

;; 汇总所有插件的 hooks；宿主用 make-hook-registry 建 registry。
(define (plugins->hooks plugins)
  (append* (for/list ([p (in-list plugins)]) (plugin-hooks p))))

;; 汇总初始 plugin-states。
(define (plugins->states plugins)
  (for/fold ([h (hash)]) ([p (in-list plugins)])
    (hash-set h (plugin-id p) (plugin-state p))))

;; 汇总插件命令表；先安装的插件优先。
(define (plugins->command-table plugins)
  (apply command-table-merge (map owned-command-table-table
                                  (plugins->command-tables plugins))))

;; host 用列表逐张查，guarded-command 不成立时继续下一张。
(define (plugins->command-tables plugins)
  (for/list ([p (in-list plugins)]
             #:when (command-table? (plugin-commands p)))
    (owned-command-table (plugin-id p) (plugin-commands p))))

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
      (append*
       (for/list ([svc (in-list (plugin-services p))])
         (define kind (service-name svc))
         (append
          (list (contribution point/job-service kind id 0 0 (service-handler svc)))
          (if (plugin-handle-job p)
              (list (contribution point/job-result kind id 0 0 (plugin-handle-job p)))
              '()))))))))
