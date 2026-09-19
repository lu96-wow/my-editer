#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "width.rkt" rackunit)

;;; window.rkt —— 视口：buffer 引用 + 本窗口光标 + 滚动位置 + 尺寸
;;;
;;; buffer 是文档（无光标）；window 是「怎么看它」，并持有自己的 point。
;;; 一个 buffer 可被多个 window 绑定，各自有独立的 point。
;;;
;;; 本层只做**纯视图**：光标导航、滚动、尺寸、投影（window->screen）。
;;; **编辑不在这里**——编辑会改共享 buffer，必须经 document 的漏斗（document-edit），
;;; 否则多视图会分叉。window 是视图原子，不是编辑入口。

(provide
 (struct-out window)
 window-open
 check-mode
 snap-left-col
 window-set-buffer
 window-set-point
 window-set-mode
 window-set-top
 window-set-left
 window-set-top-seg
 window-set-size
 window-scroll
 window-hscroll
 window-goto
 window-left
 window-right
 window-home
 window-end)

(struct window
  (buffer   ; buffer.rkt     文档（编辑时换成新 buffer）
   point    ; point.rkt     本窗口光标
   mode     ; 'clip | 'wrap
   top-line ; nat            clip：顶 buffer 行；wrap：顶部所在 buffer 行
   left-col ; nat            clip：水平滚动列；wrap：恒 0
   top-seg  ; nat            wrap：顶部行的第几个折行段；clip：恒 0
   height   ; nat            可见行数
   width)   ; nat            可见列数
  #:transparent)

(define (window-open b [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height must be >= 1, got ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width must be >= 1, got ~a" width))
  (window b (point 0 0) 'clip 0 0 0 height width))

;;; ---------- point 夹紧 ----------

(define (clamp-point b p)
  (define n (buffer-line-count b))
  (define l (max 0 (min (point-line p) (sub1 n))))
  (define len (string-length (buffer-line-ref b l)))
  (point l (max 0 (min (point-col p) len))))

(define (window-set-buffer w b)
  (struct-copy window w [buffer b] [point (clamp-point b (window-point w))]))

(define (window-set-point w p)
  (struct-copy window w [point (clamp-point (window-buffer w) p)]))

;;; ---------- 视图状态 ----------

;; mode 枚举检查。`window-set-mode` 立即查（报错点与设置点合一，见 ARCHITECTURE §8.5 A4）；
;; view.rkt 的渲染/跟随路径复用它做**延迟兜底** —— `window` 的构造器是公开的，
;; 仍可能被绕过造出非法 mode。
(define (check-mode who m)
  (unless (memq m '(clip wrap))
    (error who "mode 必须是 'clip 或 'wrap，得到 ~a" m)))

(define (window-set-mode w m)     (check-mode 'window-set-mode m) (struct-copy window w [mode m]))
(define (window-set-top w n)      (struct-copy window w [top-line (max 0 n)]))
;; 水平滚动的参考行：顶行（`left-col` 作用于整个可见区，顶行是它的代表）。
(define (left-ref-text w)
  (define b (window-buffer w))
  (define n (buffer-line-count b))
  (buffer-line-ref b (max 0 (min (window-top-line w) (sub1 n)))))

;; 把水平列吸附到**字符起点**：落在宽字符右半会画出半格空白（ARCHITECTURE §8.5 D2）。
;; 与 `snap-column-forward` 的区别：**不夹到行尾** —— 超过行宽的列原样保留，那是
;; 「滚过短行尾部」的合法状态（短行显示空、更长的行显示尾部）。
(define (snap-left-col text col)
  (if (<= col (string-display-width text))
      (snap-column-forward text col)
      col))

;; 水平滚动/设置一律吸附到字符起点（与 `window-ensure-point` 的右界吸附一致）。
(define (window-set-left w n)
  (struct-copy window w [left-col (snap-left-col (left-ref-text w) (max 0 n))]))
(define (window-hscroll w delta)
  (window-set-left w (+ (window-left-col w) delta)))
(define (window-set-top-seg w n)  (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

;;; ---------- 光标导航（只动 point，直接返回 window）----------

(define (window-goto w l c)
  (window-set-point w (point l c)))

(define (window-left w)
  (define p (window-point w))
  (define l (point-line p))
  (define o (point-col p))
  (cond [(> o 0) (window-set-point w (point l (sub1 o)))]
        [(> l 0) (define pl (sub1 l))
                 (define n (string-length (buffer-line-ref (window-buffer w) pl)))
                 (window-set-point w (point pl n))]
        [else w]))

(define (window-right w)
  (define p (window-point w))
  (define l (point-line p))
  (define o (point-col p))
  (define n (buffer-line-count (window-buffer w)))
  (cond [(< o (string-length (buffer-line-ref (window-buffer w) l)))
         (window-set-point w (point l (add1 o)))]
        [(< l (sub1 n))
         (window-set-point w (point (add1 l) 0))]
        [else w]))

(define (window-home w)
  (window-set-point w (point (point-line (window-point w)) 0)))

(define (window-end w)
  (define l (point-line (window-point w)))
  (window-set-point w
    (point l (string-length (buffer-line-ref (window-buffer w) l)))))

;;; ---------- 测试 ----------

(module+ test
  (define b (buffer-open "a\nb\nc\nd\ne"))

  ;; 基本
  (define w (window-open b 2 10))
  (check-equal? (window-buffer w) b)
  (check-equal? (window-point w) (point 0 0))
  (check-equal? (window-mode w) 'clip)
  (check-equal? (window-top-line w) 0)
  (check-equal? (window-left-col w) 0)
  (check-equal? (window-top-seg w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-width w) 10)

  ;; point 夹紧
  (check-equal? (window-point (window-set-point w (point 3 99))) (point 3 1))
  (check-equal? (window-point (window-set-point w (point 99 0))) (point 4 0))

  ;; window-set-buffer 夹紧 point
  (check-equal? (window-point (window-set-buffer w (buffer-open ""))) (point 0 0))
  (check-equal? (window-point (window-set-buffer (window-set-point w (point 2 0))
                                                 (buffer-open "a")))
                (point 0 0))

  ;; 导航
  (define w1 (window-right w))
  (check-equal? (window-point w1) (point 0 1))
  (define w2 (window-left w1))
  (check-equal? (window-point w2) (point 0 0))
  (define w3 (window-left w2))          ; 行首不动
  (check-equal? (window-point w3) (point 0 0))
  (define w4 (window-end w))
  (check-equal? (window-point w4) (point 0 1))
  (define w5 (window-right w4))         ; 行尾 → 下一行首
  (check-equal? (window-point w5) (point 1 0))
  (define w6 (window-left w5))          ; 回上一行尾
  (check-equal? (window-point w6) (point 0 1))
  (define w7 (window-goto w 2 0))
  (check-equal? (window-point w7) (point 2 0))
  (define w8 (window-home w7))
  (check-equal? (window-point w8) (point 2 0))

  ;; 滚动 / 尺寸
  (check-equal? (window-top-line (window-scroll w 2)) 2)
  (check-equal? (window-top-line (window-scroll w -5)) 0)
  (check-equal? (window-top-line (window-set-top w 4)) 4)
  (define wh (window-hscroll (window-set-left w 3) 2))
  (check-equal? (window-left-col wh) 5)
  (check-equal? (window-hscroll w -10) (window-set-left w 0))
  (define ws (window-set-size w 30 100))
  (check-equal? (window-height ws) 30)
  (check-equal? (window-width ws) 100)
  (check-equal? (window-mode (window-set-mode w 'wrap)) 'wrap)
  (check-equal? (window-top-seg (window-set-top-seg w 3)) 3)

  ;; D2 回归：水平滚动吸附到字符起点，但**不夹到行尾**（滚过短行尾部是合法状态）
  (define bd (buffer-open "中abc"))                 ; 中占显示列 0-1，'a' 在 2
  (define wd (window-open bd 2 4))
  (check-equal? (window-left-col (window-set-left wd 0)) 0)     ; 边界不动
  (check-equal? (window-left-col (window-set-left wd 1)) 2)     ; 右半格 → 下一字符起点
  (check-equal? (window-left-col (window-set-left wd 2)) 2)     ; 已是字符起点
  (check-equal? (window-left-col (window-hscroll wd 1)) 2)      ; hscroll 同样吸附
  (check-equal? (window-left-col (window-set-left wd 99)) 99)   ; 滚过行尾：原样保留

  ;; A4 回归：未知 mode 立即报错（原来 set-mode 收下任意值，只在渲染路径延迟报错/静默当 wrap）
  (check-exn exn:fail? (lambda () (window-set-mode (window-open (buffer-open "abc") 3 10) 'C)))

  (displayln "window.rkt: all tests passed"))
