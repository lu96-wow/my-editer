#lang racket

;;; lab/io/tui.rkt —— racket-tui 后端（唯一 require tui 的文件）
;;;
;;; 两个职责，别的一概不做：
;;;   入：tui 事件 ──tui-event->input──▶ lab/input.rkt 的值 ──▶ 命令层
;;;   出：core screen ──output/present!──▶ span ──display 协议──▶ 终端字节
;;;
;;; 它不认识命令、不碰文档、不做焦点、不存业务状态。
;;; 换 racket/gui = 另写一个同样实现 display 协议 + 事件翻译的适配器，命令/模型/core 一行不改。

(require (except-in tui cursor-col mouse-modifiers)
         "../output.rkt"
         "../input.rkt")

(provide make-tui-display
         tui-event->input
         run-tui!)

;;; ---------- style → ANSI ----------

(define (style->ops st)
  (bytes-append
   (if (style-fg st) (apply format-rgb-fg-base (style-fg st)) #"")
   (if (style-bg st) (apply format-rgb-bg-base (style-bg st)) #"")
   (if (style-bold? st) format-bold #"")
   (if (style-italic? st) format-italic #"")
   (if (style-underline? st) format-underline #"")
   (if (style-reverse? st) format-reverse #"")))

;;; ---------- display 实现 ----------

(define (make-tui-display)
  (define buf (box '()))
  (define (emit! x) (set-box! buf (cons x (unbox buf))))
  (define (flush-buf!)
    (define parts (reverse (unbox buf)))
    (set-box! buf '())
    (unless (null? parts)
      (put-bytes (apply bytes-append parts))
      (flush!)))
  (make-display
   #:init! (lambda () (emit! format-cursor-hide))
   #:exit! (lambda () (emit! format-cursor-show) (flush-buf!))
   #:size (lambda () (get-window-size))                    ; → (values rows cols)
   #:clear! (lambda () (emit! format-screen-clear))
   #:put! (lambda (row col text st)
            (emit! (bytes-append (format-cursor-move (add1 row) (add1 col))
                               (style->ops st)
                               (format-content text)
                               format-reset)))
   #:flush! flush-buf!))

;;; ---------- tui 事件 → input ----------
;;; tui 特有的东西全在这里：终端把 Ctrl+字母给成大写（归一成小写）；终端只在按住键
;;; 拖动时上报 move（所以它就是 'drag）；终端 scroll 带 up/down 按钮（转 wheel）。

(define (tui-mods m)
  (modifiers (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f))

(define (tui-event->input ev)
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
       [(move)    (mouse 'drag #f row col (tui-mods m))]
       [(scroll)  (wheel (if (eq? button 'up) 'up 'down) row col (tui-mods m))]
       [else #f])]
    [(resize-event r c) (resize r c)]
    [_ #f]))

;;; ---------- 主循环 ----------
;;; draw!   : (-> void)          初始 + 每次事件后重绘（由上层用 present! 实现）
;;; handle! : (input -> void)    处理一个抽象输入
;;; stop?   : (-> boolean?)      退出条件（命令层的 quit 落在这里）
;;; #:display : 可选的 display，用来在 with-tui 内部 init!/exit!。

(define (run-tui! draw! handle! [stop? (lambda () #f)] #:display [disp #f])
  ;; 鼠标 / 括号粘贴由 with-tui（tui-init）自动开启。
  (with-tui
   (lambda ()
     (when disp (display-init! disp))
     (dynamic-wind
      void
      (lambda ()
        (draw!)
        (loop-input/stop (stop?)
         (build-input
          #:any (lambda (ev)
                  (define in (tui-event->input ev))
                  (when in (handle! in))))))
      (lambda () (when disp (display-exit! disp)))))))
