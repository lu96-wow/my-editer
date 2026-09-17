#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" rackunit)

;;; window.rkt —— 视口：buffer 引用 + 本窗口光标 + 滚动位置 + 尺寸
;;;
;;; buffer 是文档（无光标）；window 是「怎么看它」，并持有自己的 point。
;;; 一个 buffer 可被多个 window 绑定，各自有独立的 point。
;;;
;;; 光标操作（导航 / 编辑）都在本层：用 window-point 驱动 buffer 的显式位置原语，
;;; 再把新 buffer 与 post-edit 光标写回 window。滚动仍是纯视图状态。

(provide
 (struct-out window)
 window-open
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
 window-end
 window-insert-char
 window-insert-string
 window-newline
 window-backspace
 window-delete)

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

(define (window-set-mode w m)     (struct-copy window w [mode m]))
(define (window-set-top w n)      (struct-copy window w [top-line (max 0 n)]))
(define (window-set-left w n)     (struct-copy window w [left-col (max 0 n)]))
(define (window-set-top-seg w n)  (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

(define (window-hscroll w delta)
  (struct-copy window w [left-col (max 0 (+ (window-left-col w) delta))]))

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

;;; ---------- 编辑（用本窗口 point 驱动 buffer 显式位置原语）----------

;; edit-fn : (lambda (b line col) (values new-buffer desc))
;; 编辑成功后，把新 buffer 写回 window，并把光标设到 post-edit 位置。
(define (window-edit w edit-fn)
  (define b (window-buffer w))
  (define p (window-point w))
  (define-values (b* d) (edit-fn b (point-line p) (point-col p)))
  (if d
      (values (struct-copy window w
                [buffer b*]
                [point (edit-desc-after-position d)])
              d)
      (values w #f)))

(define (window-insert-char w ch)
  (window-edit w (lambda (b l c) (buffer-insert-char b l c ch))))

(define (window-insert-string w s)
  (window-edit w (lambda (b l c) (buffer-insert-string b l c s))))

(define (window-newline w)
  (window-edit w (lambda (b l c) (buffer-newline b l c))))

(define (window-backspace w)
  (window-edit w (lambda (b l c) (buffer-backspace b l c))))

(define (window-delete w)
  (window-edit w (lambda (b l c) (buffer-delete b l c))))

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

  ;; 编辑：point 随编辑跟进
  (define b0 (buffer-open "hello\nworld"))
  (define w0 (window-open b0))
  (define-values (wi di) (window-insert-char w0 #\X))
  (check-equal? (buffer->string (window-buffer wi)) "Xhello\nworld")
  (check-equal? (window-point wi) (point 0 1))
  (check-equal? di (edit-desc 0 0 0 0 "X"))

  ;; 在非零列插入，point 正确前进（旧 bug：丢掉 s-col）
  (define wg1 (window-goto w0 0 2))
  (define-values (wi2 di2) (window-insert-char wg1 #\Y))
  (check-equal? (buffer->string (window-buffer wi2)) "heYllo\nworld")
  (check-equal? (window-point wi2) (point 0 3))
  (check-equal? di2 (edit-desc 0 2 0 2 "Y"))

  (define-values (wn dn) (window-newline w0))
  (check-equal? (buffer->string (window-buffer wn)) "\nhello\nworld")
  (check-equal? (window-point wn) (point 1 0))
  (check-equal? dn (edit-desc 0 0 0 0 "\n"))

  ;; backspace 合并
  (define wd1 (window-goto w0 1 0))
  (define-values (wb db) (window-backspace wd1))
  (check-equal? (buffer->string (window-buffer wb)) "helloworld")
  (check-equal? (window-point wb) (point 0 5))
  (check-equal? db (edit-desc 0 5 1 0 ""))

  ;; delete 合并
  (define wd2 (window-goto w0 0 5))
  (define-values (wdel dd) (window-delete wd2))
  (check-equal? (buffer->string (window-buffer wdel)) "helloworld")
  (check-equal? (window-point wdel) (point 0 5))

  ;; 无操作：原样返回
  (define-values (wnop dnop) (window-backspace w0))
  (check-eq? wnop w0)
  (check-false dnop)

  ;; 多行插入
  (define-values (wp dp) (window-insert-string w0 "X\nY"))
  (check-equal? (buffer->string (window-buffer wp)) "X\nYhello\nworld")
  (check-equal? (window-point wp) (point 1 1))

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

  (displayln "window.rkt: all tests passed"))
