#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "width.rkt" rackunit)

;;; window.rkt —— 视口：buffer 引用 + 本窗口光标 + 滚动位置 + 尺寸
;;;
;;; buffer 是文档（无光标）；window 是「怎么看它」，并持有自己的 point。
;;; 一个 buffer 可被多个 window 绑定，各有独立光标。
;;;
;;; 本层是**纯视图**：导航、滚动、尺寸。**编辑不在这里**——编辑改共享 buffer，
;;; 必须经 document 的漏斗（document-edit），否则多视图会分叉。
;;;
;;; 坐标：point 的 col 是**字符索引**；top-line/top-seg/left-col 是**显示列/行**。

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
  (buffer   ; buffer
   point    ; point      本窗口光标
   mode     ; 'clip|'wrap
   top-line ; nat        clip：顶 buffer 行；wrap：顶部所在 buffer 行
   left-col ; nat        clip：水平滚动列；wrap：恒 0
   top-seg  ; nat        wrap：顶部行的第几个折行段；clip：恒 0
   height   ; nat        可见行数
   width)   ; nat        可见列数
  #:transparent)

(define (window-open b [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height 必须 ≥ 1，得到 ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width 必须 ≥ 1，得到 ~a" width))
  (window b (point 0 0) 'clip 0 0 0 height width))

;;; ---------- 光标夹紧 ----------

(define (clamp-point b p)
  (define n (buffer-line-count b))
  (define l (max 0 (min (point-line p) (sub1 n))))
  (point l (max 0 (min (point-col p) (string-length (buffer-line-ref b l))))))

(define (window-set-buffer w b)
  (struct-copy window w [buffer b] [point (clamp-point b (window-point w))]))

(define (window-set-point w p)
  (struct-copy window w [point (clamp-point (window-buffer w) p)]))

;;; ---------- 视图状态 ----------

(define (check-mode who m)
  (unless (memq m '(clip wrap))
    (error who "mode 必须是 'clip 或 'wrap，得到 ~a" m)))

(define (window-set-mode w m) (check-mode 'window-set-mode m) (struct-copy window w [mode m]))
(define (window-set-top w n)  (struct-copy window w [top-line (max 0 n)]))
(define (window-set-top-seg w n) (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

;; 水平滚动的参考行 = 顶行（left-col 作用于整个可见区，顶行是代表）。
(define (left-ref-text w)
  (define b (window-buffer w))
  (define n (buffer-line-count b))
  (buffer-line-ref b (max 0 (min (window-top-line w) (sub1 n)))))

;; 把显示列吸附到字符起点：落在宽字符右半会画出半格空白。
;; **不夹到行尾** —— 超过行宽的列原样保留（「滚过短行尾部」是合法状态）。
(define (snap-left-col text col)
  (if (<= col (string-display-width text))
      (snap-column-forward text col)
      col))

(define (window-set-left w n)
  (struct-copy window w [left-col (snap-left-col (left-ref-text w) (max 0 n))]))
(define (window-hscroll w delta)
  (window-set-left w (+ (window-left-col w) delta)))

;;; ---------- 导航（纯 point 操作）----------

(define (window-goto w l c)
  (window-set-point w (point l c)))

(define (window-left w)
  (define p (window-point w))
  (define l (point-line p)) (define o (point-col p))
  (cond
    [(> o 0) (window-set-point w (point l (sub1 o)))]
    [(> l 0) (define pl (sub1 l))
             (window-set-point w (point pl (string-length (buffer-line-ref (window-buffer w) pl))))]
    [else w]))

(define (window-right w)
  (define p (window-point w))
  (define l (point-line p)) (define o (point-col p))
  (define n (buffer-line-count (window-buffer w)))
  (cond
    [(< o (string-length (buffer-line-ref (window-buffer w) l)))
     (window-set-point w (point l (add1 o)))]
    [(< l (sub1 n)) (window-set-point w (point (add1 l) 0))]
    [else w]))

(define (window-home w)
  (window-set-point w (point (point-line (window-point w)) 0)))

(define (window-end w)
  (define l (point-line (window-point w)))
  (window-set-point w (point l (string-length (buffer-line-ref (window-buffer w) l)))))

;;; ---------- 测试 ----------

(module+ test
  (define b (buffer-open "a\nb\nc\nd\ne"))
  (define w (window-open b 2 10))

  (check-equal? (window-buffer w) b)
  (check-equal? (window-point w) (point 0 0))
  (check-equal? (window-mode w) 'clip)
  (check-equal? (window-top-line w) 0)
  (check-equal? (window-top-seg w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-width w) 10)

  ;; 光标夹紧
  (check-equal? (window-point (window-set-point w (point 3 99))) (point 3 1))
  (check-equal? (window-point (window-set-point w (point 99 0))) (point 4 0))
  (check-equal? (window-point (window-set-buffer w (buffer-open ""))) (point 0 0))

  ;; 导航
  (check-equal? (window-point (window-right w)) (point 0 1))
  (check-equal? (window-point (window-left (window-right w))) (point 0 0))
  (check-equal? (window-point (window-left w)) (point 0 0))          ; 行首不动
  (check-equal? (window-point (window-right (window-end w))) (point 1 0))
  (check-equal? (window-point (window-left (window-right (window-end w)))) (point 0 1))
  (check-equal? (window-point (window-home (window-goto w 2 0))) (point 2 0))

  ;; 滚动 / 尺寸
  (check-equal? (window-top-line (window-scroll w 2)) 2)
  (check-equal? (window-top-line (window-scroll w -5)) 0)
  (check-equal? (window-top-line (window-set-top w 4)) 4)
  (check-equal? (window-left-col (window-hscroll (window-set-left w 3) 2)) 5)
  (check-equal? (window-set-size w 30 100) (window-set-size w 30 100))
  (check-equal? (window-mode (window-set-mode w 'wrap)) 'wrap)
  (check-equal? (window-top-seg (window-set-top-seg w 3)) 3)

  ;; 水平吸附：宽字符右半 → 下一字符起点；滚过行尾保留
  (define wd (window-open (buffer-open "中abc") 2 4))
  (check-equal? (window-left-col (window-set-left wd 0)) 0)
  (check-equal? (window-left-col (window-set-left wd 1)) 2)
  (check-equal? (window-left-col (window-set-left wd 2)) 2)
  (check-equal? (window-left-col (window-set-left wd 99)) 99)

  ;; 未知 mode → 报错
  (check-exn exn:fail? (lambda () (window-set-mode w 'bad)))

  (displayln "window.rkt: all tests passed"))
