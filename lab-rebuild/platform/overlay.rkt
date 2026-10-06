#lang racket

(require "../../core/editor.rkt"
         "layout/main.rkt"
         "state.rkt")

;;; lab-rebuild/platform/overlay.rkt —— 装饰图层 provider 注册表 + 浮层绘制原语
;;;
;;; 功能浮层（补全菜单 / 文档浮窗 / …）不写死在 app/render.rkt：
;;; 各自注册一个 provider `(app -> (listof pane))`，平台每帧把结果拼到装饰图层。
;;; provider 自己按 `(app-mode a)` 决定画不画。
;;;
;;; 这里还提供浮层公用的**绘制原语**（实线框 / 锚点坐标），让功能包不必 require app/render。
;;; 分割条由平台自己画（app-bar-panes），不走 provider。

(provide overlay-register! overlay-unregister! overlay-clear! overlay-panes
         anchor-screen-pos
         box-line box-hline frame-pane
         box-bface box-tface
         box-tl box-tr box-bl box-br box-lt box-rt)

(define providers '())

(define (overlay-register! proc)
  (unless (procedure? proc) (error 'overlay-register! "需要过程，得到 ~a" proc))
  (set! providers (append providers (list proc)))
  proc)

(define (overlay-unregister! proc)
  (set! providers (remove proc providers))
  (void))

(define (overlay-clear!)
  (set! providers '())
  (void))

(define (overlay-panes a)
  (append* (for/list ([p (in-list providers)]) (p a))))

;;; ================= 锚点 =================
;;
;; 光标所在 view 的屏幕绝对坐标（视口内坐标 + 窗格 x/y）。
;; ⚠ 光标滚出视口时 editor-view-point->screen-position 返回 (values #f #f)，
;; 此处原样透传 → 调用方跳过浮层。
(define (anchor-screen-pos a vid p)
  (define ed (app-ed a))
  (define rect
    (for/first ([r (in-list (layout-result-panes (app-layout-result a)))]
                #:when (eqv? (rectangle-view-id r) vid)) r))
  (define-values (row col) (editor-view-point->screen-position ed vid p))
  (if row
      (values (if rect (+ (rectangle-y rect) row) row)
              (if rect (+ (rectangle-x rect) col) col))
      (values #f #f)))

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
