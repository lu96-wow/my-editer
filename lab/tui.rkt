#lang racket

;;; ============================================================================
;;; tui.rkt —— 终端后端（**唯一 require tui 的文件**）
;;; ============================================================================
;;;
;;;   racket lab-rebuild/tui.rkt
;;;
;;; 后端只有两个职责，别的一概不做：
;;;
;;;   入：tui 事件 ──event->input──▶ input.rkt 的中间层输入 ──▶ handle
;;;   出：init/render 的 core screen ──screen-patch──▶ 终端字节
;;;
;;; 它不认识命令、不碰文档、不做焦点、不存业务状态（只存上一帧用于增量）。
;;; 换 racket/gui 后端 = 另写一个这样的适配器：把 gui 事件译成 input.rkt 的输入，
;;; 把 core screen 画进画布；state/tree/buffer/status/command/core 一行不改。

(require (except-in tui cursor-col mouse-modifiers)
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "theme.rkt"
         "input.rkt"
         "state.rkt"
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

;;; ---------- tui 事件 → 中间层输入 ----------
;;; tui 特有的东西全在这里：终端把 Ctrl+字母给成大写（归一成小写）；终端只在
;;; 按住键拖动时上报 move（所以它就是 'drag）；终端 scroll 带 up/down 按钮（转 wheel）。

(define (tui-mods m) (modifiers (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f))

(define (event->input ev)
  (match ev
    ;; Ctrl+字母：终端给大写 → 归一为小写（后端特化，中间层不做）。
    [(key-event k m) (key (if (and (mods-ctrl? m) (char? k)) (char-downcase k) k) (tui-mods m))]
    [(paste-event _ s) (text s modifiers-none)]
    ;; 鼠标 x/y 是 1-based → 转成 0-based 屏幕格。
    [(mouse-event action button x y m)
     (define row (max 0 (sub1 y)))
     (define col (max 0 (sub1 x)))
     (case action
       [(press)   (mouse 'press button row col (tui-mods m))]
       [(release) (mouse 'release button row col (tui-mods m))]
       ;; 终端只在按住键拖动时上报 move → 'drag（按钮未知，给 #f）。
       [(move)    (mouse 'drag #f row col (tui-mods m))]
       ;; 终端滚轮：scroll 带 up/down 按钮 → 独立 wheel 事件。
       [(scroll)  (wheel (if (eq? button 'up) 'up 'down) row col (tui-mods m))]
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
