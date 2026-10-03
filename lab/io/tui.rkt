#lang racket

;;; lab/io/tui.rkt —— racket-tui 后端（唯一 require tui 的文件）
;;;
;;; 两个职责，别的一概不做：
;;;   入：tui build-input（分类）──normalize-*──▶ lab/protocol.rkt 的值 ──▶ 命令层
;;;   出：core screen ──output/present!──▶ span ──display 协议──▶ 终端字节
;;;
;;; 它不认识命令、不碰文档、不做焦点、不存业务状态。
;;; 换 racket/gui = 另写一个同样实现 display 协议 + 事件翻译的适配器，命令/模型/core 一行不改。

(require (except-in tui cursor-col mouse-modifiers)
         "../output.rkt"
         "../protocol.rkt")

(provide make-tui-display
         normalize-key
         normalize-mouse
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

;;; ---------- 事件 → input ----------
;;; build-input 已经做了「命名键 / 可打印键 / 粘贴 / 鼠标 / 尺寸」的分类（命名键快捷回调
;;; + text-key?），所以这里**不再用 #:any 重判**，只补 tui 没做的两件归一：
;;;   Ctrl+字母：终端给大写 → 小写；
;;;   鼠标 1-based → 0-based；终端 move = 按住拖动 → 'drag；scroll 的 up/down → wheel。

(define (tui-mods m)
  (modifiers (mods-ctrl? m) (mods-alt? m) (mods-shift? m) #f))

;; 命名键 / Ctrl·Alt 组合键 → key（可打印键走 build-input 的 #:text，不到这里）。
(define (normalize-key k m)
  (key (if (and (mods-ctrl? m) (char? k)) (char-downcase k) k)
       (tui-mods m)))

(define (normalize-mouse action button x y m)
  (define row (max 0 (sub1 y)))
  (define col (max 0 (sub1 x)))
  (case action
    [(press)   (mouse 'press button row col (tui-mods m))]
    [(release) (mouse 'release button row col (tui-mods m))]
    [(move)    (mouse 'drag #f row col (tui-mods m))]   ; 终端只在按住拖动时上报 move
    [(scroll)  (wheel (if (eq? button 'up) 'up 'down) row col (tui-mods m))]
    [else #f]))

;;; ---------- 主循环 ----------
;;; draw!   : (-> void)          初始 + 每次事件后重绘（由上层用 present! 实现）
;;; handle! : (input -> void)    处理一个抽象输入
;;; stop?   : (-> boolean?)      退出条件（命令层的 quit 落在这里）
;;; #:display : 可选的 display，用来在 with-tui 内部 init!/exit!。

(define (run-tui! draw! handle! [stop? (lambda () #f)] #:display [disp #f])
  ;; build-input 负责分类（可打印键→#:text、粘贴→#:text、命名键/Ctrl 组合→#:key…），
  ;; 各回调只把值归一成 lab/protocol.rkt 的 input。
  (define (on-key k m) (handle! (normalize-key k m)))
  (define (on-text s) (handle! (text s modifiers-none)))
  (define (on-mouse a b x y m) (define in (normalize-mouse a b x y m)) (when in (handle! in)))
  (define (on-resize r c) (handle! (resize r c)))
  ;; 鼠标 / 括号粘贴由 with-tui（tui-init）自动开启。
  (with-tui
   (lambda ()
     (when disp (display-init! disp))
     (dynamic-wind
      void
      (lambda ()
        (draw!)
        (loop-input/stop (stop?)
         (build-input #:key on-key #:text on-text
                      #:mouse on-mouse #:resize on-resize)))
      (lambda () (when disp (display-exit! disp)))))))

;;; ---------- 输入翻译单测（无需终端） ----------

(module+ test
  (require rackunit)

  ;; normalize-key：命名键透传；Ctrl+字母的终端大写 → 小写
  (check-equal? (normalize-key 'enter no-mods) (key 'enter modifiers-none))
  (check-equal? (normalize-key #\a no-mods) (key #\a modifiers-none))
  (check-equal? (normalize-key #\B (mods #t #f #f))
                (key #\b (modifiers #t #f #f #f)))
  ;; normalize-mouse：1-based → 0-based；move = drag；scroll → wheel
  (check-equal? (normalize-mouse 'press 'left 3 5 no-mods)
                (mouse 'press 'left 4 2 modifiers-none))
  (check-equal? (normalize-mouse 'move #f 3 5 no-mods)
                (mouse 'drag #f 4 2 modifiers-none))
  (check-equal? (normalize-mouse 'scroll 'up 1 1 no-mods)
                (wheel 'up 0 0 modifiers-none))
  (check-equal? (normalize-mouse 'scroll 'down 1 1 no-mods)
                (wheel 'down 0 0 modifiers-none))

  (displayln "lab/io/tui.rkt: all tests passed"))
