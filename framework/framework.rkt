#lang racket

(require "../core/view/events.rkt" "../core/view/frame.rkt"
         "slots.rkt" rackunit)

;;; framework.rkt —— 机械组合层：config + framework-handle/render/status/run
;;;
;;; 只做路由与装配，不含任何具体命令/布局/边框行为：
;;;   - 事件按运行时类型分派到命令槽
;;;   - 渲染按 layout → pieces → compose 装配
;;;   - 编辑管线（插件+同步）不自动执行，命令作者自由调用 core 原语
;;;   - 后端无关：read 注入事件、output 注入绘制
;;;
;;; 插件只有一种：buffer -> (listof patch)，stateful 是「闭包是否带内部状态」，
;;; 不是类型；线程是可选的统一 mode（见 plugin-dag.rkt）。状态行是另一回事（view 投影）。

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
   plugins view-plugins theme)
  #:transparent)
;; plugins      : (listof plugin-spec)            文档派生（buffer → patch，闭包可带状态）
;; view-plugins : (listof (-> window status-seg))  视口投影（状态行，非文档插件）

;; 用户必须显式提供 window-commands / frame-commands / layout / compose；
;; 插件与主题默认为空。
(define (make-config #:window-commands wc
                     #:frame-commands fc
                     #:layout lo
                     #:compose co
                     #:plugins [ps '()]
                     #:view-plugins [vps '()]
                     #:theme [theme (hash)])
  (config wc fc lo co ps vps theme))

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
  (let loop ([f f0] [prev #f])
    (define scr (framework-render cfg f))
    (output scr prev (framework-status cfg f))
    (define msg (read))
    (define-values (f* done?)
      (if (async-result? msg)
          (values (frame-replace-buffer f
                                        (async-result-base-buffer msg)
                                        (async-result-buffer msg))
                  #f)
          (let-values ([(f2 _desc d?) (framework-handle cfg f msg)])
            (values f2 d?))))
    (unless done? (loop f* scr))))

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

  (displayln "framework.rkt: all tests passed"))
