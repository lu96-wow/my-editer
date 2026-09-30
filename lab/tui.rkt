#lang racket

;;; ============================================================================
;;; tui.rkt —— 终端后端（**唯一 require tui 的文件**）
;;; ============================================================================
;;;
;;;   racket lab-rebuild/tui.rkt
;;;
;;; 后端只有两个职责，别的一概不做：
;;;
;;;   入：tui 事件 ──event->input──▶ input.rkt 的抽象输入 ──▶ shell/handle
;;;   出：shell/render 的 core screen ──screen-patch──▶ 终端字节
;;;
;;; 它不认识命令、不碰文档、不做焦点、不存业务状态（只存上一帧用于增量）。
;;; 换 GUI 后端 = 另写一个这样的文件，app/tree/buffer/status/shell/core 一行不改。

(require (except-in tui cursor-col)
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "theme.rkt"
         "input.rkt"
         "editor.rkt"
         "init.rkt")

(define app-box (box #f))        ; 当前 app
(define last-screen (box #f))    ; 上一帧（增量基线）

;;; ---------- face / overlay → 真彩色 ----------
;;; face → RGB 在 theme.rkt（纯数据）；这里把 RGB 变成终端的真彩色序列。

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
  (define a (unbox app-box))
  (define-values (a1 screen) (render a))          ; 渲染并把布局尺寸/状态栏写回 app
  (set-box! app-box a1)
  (define old (unbox last-screen))
  (define-values (render* sel) (screen-patch old screen))   ; 增量：只画变化的格
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
    [(key-event k m) (key-of k (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
    [(paste-event _ s) (text s)]
    ;; 鼠标 x/y 是 1-based → 转成 0-based 屏幕坐标。
    ;; move 的 button 为 #f：终端只在按住键拖动时上报 move，所以它=拖拽。
    [(mouse-event action button x y m)
     (define row (max 0 (sub1 y)))
     (define col (max 0 (sub1 x)))
     (case action
       [(press)   (pointer 'press button row col (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
       [(release) (pointer 'release button row col (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
       [(move)    (pointer 'move #f row col (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
       [(scroll)  (pointer 'scroll button row col (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f)]
       [else #f])]
    [(resize-event r c) (resize r c)]
    [_ #f]))

;; 退出由命令层的 Ctrl-Q 触发（app 的 quit? 字段），后端不再自己认退出键。
(define (make-handler)
  (build-input
   #:any (lambda (ev)
           (define in (event->input ev))
           (when in
             (set-box! app-box (handle (unbox app-box) in))
             (draw!)))))

;;; ---------- 主循环 ----------

(module+ main
  (with-tui
   (lambda ()
     (define-values (r c) (get-window-size))
     (set-box! app-box (setup (current-directory) (max 2 (or r 24)) (max 1 (or c 80))))
     (draw!)
     (loop-input/stop (app-quit? (unbox app-box)) (make-handler)))))
