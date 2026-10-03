#lang racket

;;; lab/output.rkt —— 后端无关的输出：样式化 span + display 协议
;;;
;;; 抽象边界：
;;;
;;;   core screen / piece（后端中性的 wire format）
;;;        │  patch->spans（用 attr->style 把 face/overlay 变成 style）
;;;        ▼
;;;   span（行 / 列 / 文本 / style）—— 后端只认这个
;;;        │  tui.rkt / gui.rkt / headless.rkt 各自实现 display 协议
;;;        ▼
;;;   终端字节 / 画布像素 / 测试记录
;;;
;;; **后端不碰 core**：core 的 screen/piece 只在本文件出现，后端只实现 display 协议。
;;;
;;; style 里 fg/bg 是 RGB 或 #f（#f = 用后端默认色），后端自行决定怎么表达。

(require
 "../core/view/base/screen.rkt"
 "../core/view/patch.rkt")

(provide
 ;; ---------- 样式 / span ----------
 (struct-out style)
 style*
 default-style
 (struct-out span)

 ;; ---------- display 协议 ----------
 make-display display?
 display-init! display-exit! display-size display-clear! display-put! display-flush!

 ;; ---------- core screen/piece → span ----------
 patch->spans
 screen->spans
 present!)

;;; ---------- 样式 ----------

;; fg / bg : (or/c #f (list r g b))；attrs 是布尔。
(struct style (fg bg bold? italic? underline? reverse?) #:transparent)
(define default-style (style #f #f #f #f #f #f))

;; 关键字构造器：位置参数太吵（6 个），主题表用它更好读。
(define (style* #:fg [fg #f] #:bg [bg #f]
                #:bold? [bold? #f] #:italic? [italic? #f]
                #:underline? [underline? #f] #:reverse? [reverse? #f])
  (style fg bg bold? italic? underline? reverse?))

;; 屏幕上一段同一样式的文本；col 是**显示列**（0-based）。
(struct span (row col text style) #:transparent)

;;; ---------- display 协议 ----------

;; 后端实现六个过程：
;;   init!   : (-> void)                       进入绘制（show 窗口 / 进 alt 屏）
;;   exit!   : (-> void)                       退出绘制（还原）
;;   size    : (-> (values rows cols))         当前可见格数
;;   clear!  : (-> void)                       清整屏
;;   put!    : row col text style -> void      画一段（row/col 0-based）
;;   flush!  : (-> void)                       提交这一帧
(struct display (init-proc exit-proc size-proc clear-proc put-proc flush-proc) #:transparent)

(define (make-display #:init! init! #:exit! exit! #:size size
                      #:clear! clear! #:put! put! #:flush! flush!)
  (display init! exit! size clear! put! flush!))

(define (display-init! d) ((display-init-proc d)))
(define (display-exit! d) ((display-exit-proc d)))
(define (display-size d) ((display-size-proc d)))
(define (display-clear! d) ((display-clear-proc d)))
(define (display-put! d row col text st) ((display-put-proc d) row col text st))
(define (display-flush! d) ((display-flush-proc d)))

;;; ---------- core 输出 → span ----------

;; core piece 的 attr 有两种构造：render 用 (list 'render face)，overlay 用 (cons ch face)。
;; 在本层（唯一认识 core 的层）归一为 (channel . face) 或裸 face。
(define (normalize-attr attr)
  (cond
    [(not (pair? attr)) attr]
    [else (cons (car attr)
                (if (eq? (car attr) 'render) (cadr attr) (cdr attr)))]))

(define (patch->spans old new attr->style)
  (define-values (render sel) (screen-patch old new))
  (for/list ([p (in-list (append render sel))])
    (span (piece-row p) (piece-col p) (piece-text p)
          (attr->style (normalize-attr (piece-attr p))))))

(define (screen->spans screen attr->style)
  (patch->spans #f screen attr->style))

;;; ---------- 呈现一帧 ----------

;; 旧帧 old（可为 #f）→ 新帧 new：算差量，尺寸变了 / 首帧先清屏，逐 span 画，最后 flush。
;; 返回 new（调用方存起来当下一次基线）。
(define (present! disp old new attr->style)
  (define full? (or (not old)
                    (not (= (screen-width old) (screen-width new)))
                    (not (= (screen-height old) (screen-height new)))))
  (when full? (display-clear! disp))
  (for ([sp (in-list (patch->spans old new attr->style))])
    (display-put! disp (span-row sp) (span-col sp) (span-text sp) (span-style sp)))
  (display-flush! disp)
  new)

;;; ---------- 测试（headless） ----------

(module+ test
  (require rackunit)

  (define recorded (box '()))
  (define d (make-display
             #:init! void #:exit! void
             #:size (lambda () (values 5 10))
             #:clear! (lambda () (set-box! recorded '()))
             #:put! (lambda (r c t st) (set-box! recorded (cons (span r c t st) (unbox recorded))))
             #:flush! void))

  (define scr (screen 10 5
                      (vector (list (run 0 "hi" 'a) (run 3 "there" 'b))
                              '() '() '() '())
                      (list (cursor 1 0 #t))
                      '()))
  (define st (style '(255 0 0) #f #t #f #f #f))
  (define s (present! d #f scr (lambda (_) st)))
  (check-true (eq? s scr))
  (check-true (for/or ([sp (in-list (unbox recorded))] #:when (equal? (span-text sp) "hi")) #t))
  (check-true (for/or ([sp (in-list (unbox recorded))] #:when (equal? (span-text sp) "there")) #t))

  (displayln "lab/output.rkt: all tests passed"))
