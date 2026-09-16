#lang racket

(require "../core/view/events.rkt" "../core/view/frame.rkt"
         "../core/view/window.rkt" "../core/text/patch.rkt"
         "slots.rkt" "plugin-dag.rkt" "stateful.rkt" rackunit)

;;; framework.rkt —— 机械组合层：config + framework-handle/render/status/run
;;;
;;; 只做路由与装配，不含任何具体命令/布局/边框行为：
;;;   - 事件按运行时类型分派到命令槽
;;;   - 渲染按 layout → pieces → compose 装配
;;;   - 编辑管线（插件+同步）不自动执行，命令作者自由调用 core 原语
;;;   - 后端无关：read 注入事件、output 注入绘制

(provide
 (struct-out config)
 make-config
 framework-handle
 framework-render
 framework-status
 framework-run)

;;; ---------- 策略 bundle ----------

(struct config
  (window-commands frame-commands layout compose
   buffer-plugins stateful-plugins view-plugins theme)
  #:transparent)

;; 用户必须显式提供 window-commands / frame-commands / layout / compose；
;; 插件与主题默认为空。
(define (make-config #:window-commands wc
                     #:frame-commands fc
                     #:layout lo
                     #:compose co
                     #:buffer-plugins [bps '()]
                     #:stateful-plugins [sps '()]
                     #:view-plugins [vps '()]
                     #:theme [theme (hash)])
  (config wc fc lo co bps sps vps theme))

;;; ---------- 事件分派（机械，按运行时类型） ----------

(define (framework-handle cfg f ev)
  (define wc (config-window-commands cfg))
  (define fc (config-frame-commands cfg))
  (cond
    [(not ev) (values f #f #f)]
    [(text-event? ev)        ((window-commands-on-text wc) cfg f ev)]
    [(key-event? ev)         ((frame-commands-on-key fc) cfg f ev)]
    [(mouse-press-event? ev) ((frame-commands-on-mouse-press fc) cfg f ev)]
    [(mouse-wheel-event? ev) ((frame-commands-on-mouse-wheel fc) cfg f ev)]
    [(resize-event? ev)      ((frame-commands-on-resize fc) cfg f ev)]
    [(quit-event? ev)        ((frame-commands-on-quit fc) cfg f ev)]
    [else (values f #f #f)]))

;;; ---------- 渲染（机械装配） ----------

(define (framework-render cfg f)
  (define lo (config-layout cfg))
  (define rects ((layout-rects lo) f))
  (define pieces (frame-pieces f rects))
  ((compose-compose (config-compose cfg))
   (frame-rows f) (frame-cols f) pieces (frame-active f)))

;;; ---------- 状态行 ----------

(define (framework-status cfg f)
  (run-view-plugins (frame-active-window f) (config-view-plugins cfg)))

;;; ---------- 循环（read 注入事件，output 注入绘制） ----------

;; read : (-> (or/c #f event async-result))
;;   #f            → 空闲（重渲染）
;;   event         → 用户输入，分派给命令
;;   async-result  → 异步插件算完，按内容版本应用到 frame（stale 自动 no-op）
;; output : (-> screen (or/c #f screen) (listof status-seg) any)
(define (framework-run cfg f0 read output)
  ;; 有状态插件实例：启用时从全量 buffer 建初始状态，之后每 edit-desc 按序 fold。
  (define insts0
    (map (lambda (sp) (stateful-start sp (window-buffer (frame-active-window f0))))
         (config-stateful-plugins cfg)))
  (let loop ([f f0] [prev #f] [insts insts0])
    (define scr (framework-render cfg f))
    (output scr prev (framework-status cfg f))
    (define msg (read))
    (cond
      [(async-result? msg)
       (loop (frame-replace-buffer f
                                   (async-result-base-buffer msg)
                                   (async-result-buffer msg))
             scr insts)]
      [else
       (define-values (f* desc done?) (framework-handle cfg f msg))
       (cond
         [done? (void)]
         [desc
          ;; 编辑发生：把 desc 喂给有状态插件（不可跳步），再应用它们的投影。
          (define insts* (map (lambda (i) (stateful-feed i desc)) insts))
          (loop (statefuls-apply f* insts*) scr insts*)]
         [else (loop f* scr insts)])])))

;; 应用所有有状态插件的投影（补丁）到 active buffer；无状态插件时原样返回。
(define (statefuls-apply f insts)
  (define patches (apply append (map stateful-view insts)))
  (if (null? patches)
      f
      (let ([w (frame-active-window f)])
        (if (not w)
            f
            (let ([b (window-buffer w)])
              (frame-replace-buffer f b (buffer-apply-patches b patches)))))))

;;; ---------- 测试 ----------

(module+ test
  (require "../core/view/screen.rkt" "../core/text/buffer.rkt")
  ;; 用一个「什么都不做」的 config 验证机械分派
  (define no-wc (window-commands (lambda (c f ev) (values f #f #f))
                                 (lambda (c f ev) (values f #f #f))))
  (define no-fc (frame-commands (lambda (c f ev) (values f #f #f))
                                (lambda (c f ev) (values f #f #f))
                                (lambda (c f ev) (values f #f #f))
                                (lambda (c f ev) (values f #f #f))
                                (lambda (c f ev) (values f #f #t))))
  (define id-layout
    (layout (lambda (f) (list (list (frame-active f) 0 0 (frame-cols f) (frame-rows f))))
            (lambda (f) (list (frame-active f)))
            (lambda (f dir) f)
            (lambda (f) f)))
  (define id-compose (compose (lambda (rows cols pieces active)
                                (screen rows cols (make-vector rows '()) -1 -1))))
  (define cfg (make-config #:window-commands no-wc #:frame-commands no-fc
                           #:layout id-layout #:compose id-compose))

  (define f0 (frame-open (buffer-open "hello") 2 5))
  ;; 分派到 quit → done?
  (define-values (_f1 _d1 done1) (framework-handle cfg f0 (quit-event)))
  (check-true done1)
  ;; 未处理事件 → 原样
  (define-values (f2 d2 done2) (framework-handle cfg f0 #f))
  (check-eq? f2 f0)
  (check-false d2)
  (check-false done2)

  ;; 有状态插件投影应用：statefuls-apply 把投影补丁写到 active buffer
  (define sp
    (stateful-plugin
     (lambda (b) 0)
     (lambda (n d) (add1 n))
     (lambda (n) (if (zero? n) '() (list (patch 'edited 0 0 (list (list 0 0 1 'edited))))))))
  (define inst (stateful-feed (stateful-start sp (buffer-open "hello")) (edit-desc 0 0 0 0 "X")))
  (define f-ann (statefuls-apply f0 (list inst)))
  (check-equal? (buffer-get-text-property (window-buffer (frame-active-window f-ann)) 0 0 'edited)
                'edited)
  ;; 无投影（0 次编辑）→ 原样
  (check-eq? (statefuls-apply f0 (list (stateful-start sp (buffer-open "hello")))) f0)

  (displayln "framework.rkt: all tests passed"))
