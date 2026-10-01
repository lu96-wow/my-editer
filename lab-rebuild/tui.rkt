#lang racket

;;; ============================================================================
;;; tui.rkt —— 终端后端
;;; ============================================================================
;;;
;;;   racket lab-rebuild/tui.rkt
;;;
;;; 两个职责：
;;;   入：tui 事件 ──event->input──▶ io.rkt 的中间层输入 ──▶ handle
;;;   出：init/render 的 core screen ──screen-patch──▶ 终端字节
;;;
;;; tui 特有的东西全在这里：Ctrl+字母归一为小写；终端只在拖动时上报 move（→ 'drag）；
;;; 终端 scroll 带 up/down 按钮（→ wheel）；坐标 1-based → 0-based。

(require (except-in tui cursor-col mouse-modifiers)
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "theme.rkt"
         "io.rkt"
         "init.rkt")

(define app-box (box #f))
(define last-screen (box #f))

;;; ---------- face / overlay → 真彩色 ----------

(define (rgb-fg-bytes rgb) (if rgb (apply format-rgb-fg-base rgb) #""))
(define (rgb-bg-bytes rgb) (if rgb (apply format-rgb-bg-base rgb) #""))

(define (overlay-colors ov)
  (case ov
    [(selection) (values #f '(58 74 128))]
    [else        (values #f #f)]))

(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) format-reverse]
    [else
     (define-values (fg bg) (face-colors face))
     (define-values (ofg obg) (overlay-colors ov))
     (bytes-append (rgb-fg-bytes (or ofg fg)) (rgb-bg-bytes (or obg bg)))]))

;;; ---------- 帧 → 终端字节 ----------

(define (draw!)
  (define h (unbox app-box))
  (define-values (h1 screen) (render h))
  (set-box! app-box h1)
  (define old (unbox last-screen))
  (define-values (changed sel) (screen-patch old screen))
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! format-cursor-hide)
  (when (or (not old)
            (not (= (screen-width old) (screen-width screen)))
            (not (= (screen-height old) (screen-height screen))))
    (add! format-screen-clear))
  (for ([p (in-list (append changed sel))])
    (add! (bytes-append (format-cursor-move (add1 (piece-row p)) (add1 (piece-col p)))
                        (style-bytes (piece-attr p))
                        (format-content (piece-text p))
                        format-reset)))
  (put-bytes (apply bytes-append (reverse parts)))
  (flush!)
  (set-box! last-screen screen))

;;; ---------- tui 事件 → 中间层输入 ----------

(define (tui-mods m) (modifiers (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f))

(define (event->input ev)
  (match ev
    [(key-event k m) (key (if (and (mods-ctrl? m) (char? k)) (char-downcase k) k) (tui-mods m))]
    [(paste-event _ s) (text s modifiers-none)]
    [(mouse-event action button x y m)
     (define row (max 0 (sub1 y)))
     (define col (max 0 (sub1 x)))
     (case action
       [(press)   (mouse 'press button row col (tui-mods m))]
       [(release) (mouse 'release button row col (tui-mods m))]
       [(move)    (mouse 'drag #f row col (tui-mods m))]         ; 终端只在拖动时上报 move
       [(scroll)  (wheel (if (eq? button 'up) 'up 'down) row col (tui-mods m))]
       [else #f])]
    [(resize-event r c) (resize r c)]
    [_ #f]))

(define (make-handler)
  (build-input
   #:any (lambda (ev)
           (define in (event->input ev))
           (when in
             (set-box! app-box (handle (unbox app-box) in))
             (draw!)))))

;;; ---------- 主循环 ----------
;;; 骨架里没有退出命令：终端用 Ctrl-C。

(module+ main
  (with-tui
   (lambda ()
     (define-values (r c) (get-window-size))
     (set-box! app-box (setup (current-directory) (max 2 (or r 24)) (max 1 (or c 80))))
     (draw!)
     (loop-input/stop #f (make-handler)))))
