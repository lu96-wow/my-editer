#lang racket

(require "../core/text/buffer.rkt" "../core/text/cursor.rkt"
         "../core/text/patch.rkt"
         "../core/view/window.rkt"
         "plugin-dag.rkt" rackunit)

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
 (struct-out plugin-spec)   ; 重新导出：插件组合声明（见 plugin-dag.rkt）
 run-plugins
 run-plugins-init
 run-view-plugins)

;;; ---------- 视口派生（window → status-seg） ----------

(struct status-seg (text face) #:transparent)

(define (run-view-plugins w vps)
  (apply append (for/list ([p (in-list vps)]) (p w))))

;;; ---------- buffer 派生（插件 = buffer → patch，吃 dirty） ----------
;;; 插件现在是纯函数 buffer -> (listof patch)；组合时用 plugin-spec 声明依赖。
;;; 调度（依赖分层 + future 并行 + dirty 消费）在 plugin-dag.rkt。

(define (run-plugins b specs)
  (run-plugin-dag-sync specs b))

(define (run-plugins-init b specs)
  (if (null? specs)
      b
      (run-plugin-dag-sync specs (buffer-mark-dirty-all b))))

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
  (define b1 (run-plugins b0 (list (plugin-spec 'tag tag '()))))
  (check-equal? (buffer-get-text-property b1 0 0 'face) 'bold)
  (check-false (buffer-dirty b1))

  ;; view 插件组合器
  (define (rowcol w)
    (list (status-seg (format "Ln ~a" (add1 (cursor-line (window-point w)))) #f)))
  (check-equal? (map status-seg-text (run-view-plugins (window-open b0) (list rowcol)))
                '("Ln 1"))

  (displayln "slots.rkt: all tests passed"))
