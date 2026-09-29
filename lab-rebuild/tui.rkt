#lang racket

;;; ============================================================================
;;; tui.rkt —— 终端后端（**唯一 require tui 的文件**）
;;; ============================================================================
;;;
;;;   racket lab-rebuild/tui.rkt
;;;
;;; 只做两件事：
;;;   1) 把 tui 事件翻译成 input.rkt 的抽象输入 → shell/handle；
;;;   2) 把 core 的 screen 画到终端。
;;;
;;; 这里没有业务逻辑：不认命令、不碰文档、不做焦点。改后端只动这个文件。

(require (except-in tui cursor-col)
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "input.rkt"
         "shell.rkt")

(define app-box (box #f))
(define last-screen (box #f))
(define quit? (box #f))

;;; ---------- face / overlay → 真彩色 ----------

(define (rgb-fg-bytes rgb) (if rgb (apply format-rgb-fg-base rgb) #""))
(define (rgb-bg-bytes rgb) (if rgb (apply format-rgb-bg-base rgb) #""))

(define (face-colors face)
  (cond [(not face)             (values #f #f)]
        [(eq? face 'status)     (values '(225 225 225) '(40 44 52))]
        [else                   (values '(205 205 205) #f)]))

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

;;; ---------- 帧 → 字节 ----------

(define (draw!)
  (define a (unbox app-box))
  (define-values (a1 screen) (render a))
  (set-box! app-box a1)
  (define old (unbox last-screen))
  (define-values (render* sel) (screen-patch old screen))
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! format-cursor-hide)
  (when (or (not old)
            (not (= (screen-width old) (screen-width screen)))
            (not (= (screen-height old) (screen-height screen))))
    (add! format-screen-clear))
  (for ([p (in-list (append render* sel))])
    (add! (bytes-append (format-cursor-move (add1 (piece-row p)) (add1 (piece-col p)))
                        (style-bytes (piece-attr p))
                        (format-content (piece-text p))
                        format-reset)))
  (put-bytes (apply bytes-append (reverse parts)))
  (flush!)
  (set-box! last-screen screen))

;;; ---------- tui 事件 → 抽象输入 ----------

(define (event->input ev)
  (match ev
    [(key-event k m) (key k (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
    [(paste-event _ s) (text s)]
    [(resize-event r c) (resize r c)]
    [_ #f]))

(define (quit-key? ev)
  (match ev
    [(key-event #\q m) (and (mods-ctrl? m) (not (mods-alt? m)))]
    [_ #f]))

(define (make-handler)
  (build-input
   #:any (lambda (ev)
           (cond
             [(quit-key? ev) (set-box! quit? #t)]
             [else
              (define in (event->input ev))
              (when in
                (set-box! app-box (handle (unbox app-box) in))
                (draw!))]))))

;;; ---------- 主循环 ----------

(module+ main
  (with-tui
   (lambda ()
     (define-values (r c) (get-window-size))
     (set-box! app-box (setup (current-directory) (max 2 (or r 24)) (max 1 (or c 80))))
     (draw!)
     (loop-input/stop (unbox quit?) (make-handler)))))
