#lang racket

(require "../core/text/buffer.rkt" "../core/text/cursor.rkt"
         "../core/text/patch.rkt"
         "../core/view/window.rkt"
         "plugin-dag.rkt" "edit-plugins.rkt" rackunit)

;;; slots.rkt —— 框架的 slot 类型定义 + 组合器
;;;
;;; 每个 slot 是一个「类型 + 组合器」。绝不搞万能 Plugin 接口：
;;;   每个派生位置一个明确类型，组合器只做机械拼接。

(provide
 (struct-out status-seg)
 (struct-out layout)
 (struct-out compose)
 (struct-out window-commands)
 (struct-out frame-commands)
 (struct-out plugin-spec)    ; 插件组合声明
 (struct-out plugin-async)   ; 异步句柄
 (struct-out async-result)   ; 异步结果消息（回 UI 用）
 run-plugins
 run-plugins-init
 run-plugins-async
 run-plugins-async-init
 plugin-async-poll
 plugin-async-collect
 run-view-plugins
 ;; 编辑能力（slot #2）：编辑插件 + 编辑策略组合器
 (struct-out edit-plugin-spec)
 run-edit-plugins
 run-edit-plugins-init
 compose-edit-strategies)

;;; ---------- 视口派生（window → status-seg） ----------

(struct status-seg (text face) #:transparent)

(define (run-view-plugins w vps)
  (apply append (for/list ([p (in-list vps)]) (p w))))

;;; ---------- 编辑策略（window-commands 装饰器） ----------
;;; 输入驱动、光标敏感的编辑（auto-pair/snippet/缩进）在命令层拦截事件，
;;; 类型 = window-commands -> window-commands；compose-edit-strategies 按序包裹。
(define (compose-edit-strategies . strategies)
  (lambda (base)
    (for/fold ([wc base]) ([s (in-list strategies)]) (s wc))))

;;; ---------- 文档插件（统一：buffer → patch，闭包可带状态，吃 dirty） ----------
;;; 插件只有一种：buffer -> (listof patch)。stateful = 闭包捕获内部状态，不是类型；
;;; 线程 = plugin-spec 上统一的 mode（sync/parallel）。调度在 plugin-dag.rkt。

(define (run-plugins b specs)
  (run-plugin-dag-sync specs b))

(define (run-plugins-init b specs)
  (if (null? specs)
      b
      (run-plugin-dag-sync specs (buffer-mark-dirty-all b))))

;; 非阻塞（整轮 async）：立即返回基线 + 结果句柄；算完用 plugin-async-poll/collect 收。
(define (run-plugins-async b specs)
  (run-plugin-dag-async specs b))

(define (run-plugins-async-init b specs)
  (run-plugin-dag-async-init specs b))

;;; ---------- 布局（frame → 几何/顺序 + 布局变更） ----------

;; rects : (-> frame (listof (window-id x y w h)))
;; order : (-> frame (listof window-id))
;; split : (-> frame symbol frame)   拆 active
;; close : (-> frame frame)          关 active
(struct layout (rects order split close) #:transparent)

;;; ---------- 组合/装饰（pieces → screen，含边框） ----------

;; compose : (-> rows cols (listof piece) window-id screen)
;;   piece = (list window-id x y w h screen)
(struct compose (compose) #:transparent)

;;; ---------- 命令两层 ----------

;; 窗口级命令：语义上作用于 active window，但收 frame（自由编辑管线需要手动同步）。
;; 槽值类型 : (-> config frame 事件 (values frame desc? done?))
(struct window-commands (on-text on-key) #:transparent)

;; 帧级命令：窗口管理，优先于窗口级。
(struct frame-commands (on-key on-mouse-press on-mouse-wheel on-resize on-quit) #:transparent)

;;; ---------- 测试 ----------

(module+ test
  ;; buffer 插件组合器：插件返回 patch，组合时声明 spec
  (define b0 (buffer-open "hello\nworld"))
  (check-eq? (run-plugins b0 '()) b0)
  (define (tag b) (list (patch 'face 0 0 (list (list 0 0 1 'bold)))))
  (define b1 (run-plugins b0 (list (plugin-spec 'tag tag '() 'sync))))
  (check-equal? (buffer-get-text-property b1 0 0 'face) 'bold)
  (check-false (buffer-dirty b1))

  ;; view 插件组合器
  (define (rowcol w)
    (list (status-seg (format "Ln ~a" (add1 (cursor-line (window-point w)))) #f)))
  (check-equal? (map status-seg-text (run-view-plugins (window-open b0) (list rowcol)))
                '("Ln 1"))

  (displayln "slots.rkt: all tests passed"))
