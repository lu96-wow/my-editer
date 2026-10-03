#lang racket

;;; lab/io/gui.rkt —— racket/gui 后端（与 tui 同协议，换后端不改模型/命令）
;;;
;;; 入：gui 事件 ──gui-event->input──▶ lab/input.rkt 的值
;;; 出：span ──display 协议──▶ 画布像素（retained 网格，重画时整屏重绘）
;;;
;;; 与 tui 的差别：
;;;   · display-size 由画布像素 ÷ 字格度量得到；
;;;   · put! 只是写进网格并触发 refresh，真正绘制在 on-paint；
;;;   · 事件是回调式（非阻塞循环），由 GUI 事件队列驱动。
;;;
;;; 注意：本文件创建窗口，需要图形环境；无头环境只编译、不实例化。

(require racket/class
         racket/gui/base
         racket/draw
         "../output.rkt"
         "../input.rkt")

(provide make-gui-display
         gui-mods
         gui-mouse->input)

;;; ---------- 输入翻译 ----------

(define (gui-mods ev)
  (modifiers (send ev get-control-down)
             (send ev get-alt-down)
             (send ev get-shift-down)
             (send ev get-meta-down)))

(define (gui-button ev)
  (case (send ev get-button)
    [(left) 'left] [(middle) 'middle] [(right) 'right] [else 'left]))

;; 鼠标事件 → input（row/col 由像素 ÷ 字格得到）。非鼠标 → #f。
(define (gui-mouse->input cell-w cell-h ev)
  (and (is-a? ev mouse-event%)
       (let* ([x (send ev get-x)] [y (send ev get-y)]
              [col (max 0 (quotient x cell-w))]
              [row (max 0 (quotient y cell-h))]
              [m (gui-mods ev)]
              [wd (send ev get-wheel-delta)])
         (cond
           [(> wd 0) (wheel 'up row col m)]
           [(< wd 0) (wheel 'down row col m)]
           [(send ev button-down?) (mouse 'press (gui-button ev) row col m)]
           [(send ev button-up?)   (mouse 'release (gui-button ev) row col m)]
           [(send ev dragging?)    (mouse 'drag (gui-button ev) row col m)]
           [(send ev moving?)      (mouse 'move #f row col m)]
           [else #f]))))

;;; ---------- display 实现 ----------

(define (make-gui-display #:on-input [on-input void]
                          #:cell-w [cell-w 9]
                          #:cell-h [cell-h 18]
                          #:cols [cols 80]
                          #:rows [rows 24]
                          #:label [label "lab"])
  (define cells (make-hash))            ; (cons row col) -> (cons text style)
  (define font (make-font #:size 13 #:family 'modern))
  (define default-bg (make-color 20 22 28))
  (define default-fg (make-color 205 205 205))

  (define frame (new frame% [label label]
                     [width (* cell-w cols)] [height (* cell-h rows)]))
  (define (rgb c) (if c (apply make-color c) #f))

  (define (paint! dc)
    (send dc set-background default-bg)
    (send dc clear)
    (send dc set-font font)
    (for ([(k v) (in-hash cells)])
      (define row (car k)) (define col (cdr k))
      (define text (car v)) (define st (cdr v))
      (define x (* col cell-w)) (define y (* row cell-h))
      (define bg (or (rgb (style-bg st))
                     (and (style-reverse? st) default-fg)))
      (when bg
        (send dc set-brush bg 'solid)
        (send dc draw-rectangle x y (* cell-w (max 1 (string-length text))) cell-h))
      (send dc set-text-foreground
            (or (and (style-reverse? st) default-bg)
                (rgb (style-fg st)) default-fg))
      (send dc draw-text text x y)))

  (define canvas
    (new canvas% [parent frame]
         [paint-callback (lambda (_c dc) (paint! dc))]
         [on-size (lambda (_c w h)
                    (on-input (resize (max 1 (quotient h cell-h))
                                      (max 1 (quotient w cell-w)))))]
         [on-char (lambda (_c ev)
                    (define code (send ev get-key-code))
                    (when code (on-input (key code (gui-mods ev)))))]
         [on-event (lambda (_c ev)
                     (define in (gui-mouse->input cell-w cell-h ev))
                     (when in (on-input in)))]))

  (make-display
   #:init! (lambda () (send frame show #t))
   #:exit! (lambda () (send frame show #f))
   #:size (lambda ()                                            ; size
            (values (max 1 (quotient (send canvas get-height) cell-h))
                    (max 1 (quotient (send canvas get-width) cell-w))))
   #:clear! (lambda () (hash-clear! cells))
   #:put! (lambda (row col text st)
            (hash-set! cells (cons row col) (cons text st)))
   #:flush! (lambda () (send canvas refresh))))
