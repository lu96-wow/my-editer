#lang racket

;;; lab-rebuild/kernel/overlay.rkt —— 浮层（frame decoration）注册 + 绘制原语。
;;;
;;; 浮层是**每帧纯函数** ctx -> (listof pane)，不经 effect、不进历史。
;;; 内容类输出（状态行 / 面板 / 输入行 / 属性高亮）不走这里，走 effect（reload/attr!）。

(require "editor-api.rkt"
         "registry.rkt" "runtime.rkt" "layout.rkt")

(provide (struct-out deco)
         overlay-panes
         anchor-screen-pos
         box-line box-hline frame-pane
         box-bface box-tface
         box-tl box-tr box-bl box-br box-lt box-rt)

(struct deco (id render) #:transparent)
;; render : Ctx -> (listof pane)

;; 收集所有浮层 provider 的 pane（按 priority/name 排序）。
(define (overlay-panes ctx)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (append* (for/list ([c (in-list (reg-kind reg 'deco))])
             ((deco-render (contrib-value c)) ctx))))

;;; ================= 锚点 =================

;; 光标屏幕绝对坐标（供浮层定位）；不可见 → (values #f #f)。由 layout.rkt 提供。

;;; ================= 实线框 =================

(define box-bface 'bar)         ; 边框 face
(define box-tface 'state)       ; 文本 face
(define box-h #\u2500) (define box-v #\u2502)
(define box-tl #\u250c) (define box-tr #\u2510)
(define box-bl #\u2514) (define box-br #\u2518)
(define box-lt #\u251c) (define box-rt #\u2524)

;; 一条横框线（left / right 选角或分隔接点），内宽 cw。
(define (box-hline cw left right)
  (run 0 (string-append (string left) (make-string cw box-h) (string right)) box-bface))

;; 一条内容行：│ text ␣… │；face 可带 overlay（选中行）。
(define (box-line cw text face)
  (list (run 0 (string box-v) box-bface)
        (run 1 (string-append text (make-string (max 0 (- cw (string-length text))) #\space)) face)
        (run (add1 cw) (string box-v) box-bface)))

;; 一个实线框 pane：content 是内容行（每行 (text . face)）。
(define (frame-pane id row col cw content deep)
  (define rws
    (list->vector
     (append (list (list (box-hline cw box-tl box-tr)))
             (for/list ([c (in-list content)]) (box-line cw (car c) (cdr c)))
             (list (list (box-hline cw box-bl box-br))))))
  (pane id row col (screen (+ cw 2) (+ (length content) 2) rws '() '()) deep))
