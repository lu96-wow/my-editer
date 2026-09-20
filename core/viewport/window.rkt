#lang racket

(require "../atom/point.rkt" "../atom/selection.rkt" "../doc/buffer.rkt" "../atom/width.rkt" rackunit)

;;; viewport/window.rkt —— 视口：buffer 引用 + 本窗口的选区集合 + 滚动位置 + 尺寸
;;;
;;; buffer 是文档（无光标）；window 是「怎么看它」，持有自己的**选区集合**（至少一个）。
;;; 一个 buffer 可被多个 window 绑定，各有独立选区。
;;;
;;;   selections : (nonempty-listof selection)   已规范化（排序、去重、重叠合并）
;;;   primary    : nat                            主选区下标；光标/打字点取它的 head
;;;   空选区 (anchor=head) 就是普通光标；单个 window 至少含一个空选区。
;;;
;;; 本层是**纯视图**：导航、滚动、尺寸。**编辑不在这里**。
;;; 坐标：point 的 col 是**字符索引**；top-line/top-seg/left-col 是**显示列/行**。

(provide
 (struct-out window)
 window-open
 check-mode
 snap-left-col
 window-point
 window-selections
 window-primary
 window-set-buffer
 window-set-point
 window-set-selections
 window-map-selections
 window-clamp-selections
 window-set-mode
 window-set-top-line
 window-set-left-col
 window-set-top-seg
 window-set-size
 window-scroll-clip
 window-hscroll
 window-left
 window-right
 window-home
 window-end)

(struct window
  (buffer     ; buffer
   selections ; (nonempty-listof selection)
   primary    ; nat        主选区下标
   mode       ; 'clip|'wrap
   top-line   ; nat        clip：顶 buffer 行；wrap：顶部所在 buffer 行
   left-col   ; nat        clip：水平滚动列；wrap：恒 0
   top-seg    ; nat        wrap：顶部行的第几个折行段；clip：恒 0
   height     ; nat        可见行数
   width)     ; nat        可见列数
  #:transparent)

(define (window-open b [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height 必须 ≥ 1，得到 ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width 必须 ≥ 1，得到 ~a" width))
  (window b (list (selection (point 0 0) (point 0 0))) 0 'clip 0 0 0 height width))

;;; ---------- 光标 / 选区 ----------

(define (window-selection w) (list-ref (window-selections w) (window-primary w)))
(define (window-point w) (selection-point (window-selection w)))

(define (clamp-selection b s)
  (selection (buffer-clamp-point b (selection-anchor s))
             (buffer-clamp-point b (selection-head s))))

;; 把现有选区夹进 buffer 合法域并规范化；primary 追到它合并后的那个。
(define (window-clamp-selections w)
  (define b (window-buffer w))
  (define sels (window-selections w))
  (define pidx (window-primary w))
  (define keysel (and (< pidx (length sels)) (clamp-selection b (list-ref sels pidx))))
  (define norm (selections-normalize (map (lambda (s) (clamp-selection b s)) sels)))
  (define idx (if keysel (or (selections-index-containing norm (selection-head keysel)) 0) 0))
  (struct-copy window w [selections norm] [primary idx]))

(define (window-set-buffer w b)
  (window-clamp-selections (struct-copy window w [buffer b])))

;; 设成单个空选区（程序面「把光标放这」的语义）。
(define (window-set-point w p)
  (define q (buffer-clamp-point (window-buffer w) p))
  (struct-copy window w [selections (list (selection q q))] [primary 0]))

;; 设一组选区；primary 按输入下标选，规范化后追到合并结果。
(define (window-set-selections w sels [primary 0])
  (unless (pair? sels) (error 'window-set-selections "至少一个选区"))
  (define b (window-buffer w))
  (define keysel (and (< primary (length sels)) (clamp-selection b (list-ref sels primary))))
  (define norm (selections-normalize (map (lambda (s) (clamp-selection b s)) sels)))
  (define idx (if keysel (or (selections-index-containing norm (selection-head keysel)) 0) 0))
  (struct-copy window w [selections norm] [primary idx]))

;; 对每个选区的 head 施加 f（point → point），坍缩成空选区；primary 跟随。
;; 导航（方向键）用它：一次动所有光标。
(define (window-map-selections w f)
  (define moved (for/list ([s (in-list (window-selections w))])
                  (define p (f (selection-head s))) (selection p p)))
  (window-clamp-selections (struct-copy window w [selections moved])))

;;; ---------- 视图状态 ----------

(define (check-mode who m)
  (unless (memq m '(clip wrap))
    (error who "mode 必须是 'clip 或 'wrap，得到 ~a" m)))

(define (window-set-mode w m) (check-mode 'window-set-mode m) (struct-copy window w [mode m]))
(define (window-set-top-line w n)  (struct-copy window w [top-line (max 0 n)]))
(define (window-set-top-seg w n) (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

(define (window-scroll-clip w delta)
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

(define (window-set-left-col w n)
  (struct-copy window w [left-col (snap-left-col (left-ref-text w) (max 0 n))]))
(define (window-hscroll w delta)
  (window-set-left-col w (+ (window-left-col w) delta)))

;;; ---------- 导航（每个选区各走一步）----------
;; 方向键把每个选区坍缩到 head 后移动；新位置去重/合并。

(define (left-point b p)
  (define l (point-line p)) (define o (point-col p))
  (cond
    [(> o 0) (point l (sub1 o))]
    [(> l 0) (point (sub1 l) (string-length (buffer-line-ref b (sub1 l))))]
    [else p]))

(define (right-point b p)
  (define l (point-line p)) (define o (point-col p))
  (define n (buffer-line-count b))
  (cond
    [(< o (string-length (buffer-line-ref b l))) (point l (add1 o))]
    [(< l (sub1 n)) (point (add1 l) 0)]
    [else p]))

(define (home-point p) (point (point-line p) 0))
(define (end-point b p)
  (point (point-line p) (string-length (buffer-line-ref b (point-line p)))))

(define (window-left w)  (window-map-selections w (lambda (p) (left-point  (window-buffer w) p))))
(define (window-right w) (window-map-selections w (lambda (p) (right-point (window-buffer w) p))))
(define (window-home w)  (window-map-selections w home-point))
(define (window-end w)   (window-map-selections w (lambda (p) (end-point (window-buffer w) p))))

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
  (check-equal? (window-point (window-home (window-set-point w (point 2 0)))) (point 2 0))

  ;; 多选区：设一组，导航一次动全部
  (define ws (window-open (buffer-open "abcde\nfghij") 3 10))
  (define wm (window-set-selections ws (list (selection (point 0 0) (point 0 0))
                                             (selection (point 0 2) (point 0 2)))))
  (check-equal? (length (window-selections wm)) 2)
  (check-equal? (map selection-head (window-selections (window-left wm)))
                (list (point 0 0) (point 0 1)))       ; 第一不动(行首)，第二左移
  (check-equal? (length (window-selections (window-right wm))) 2)  ; 两光标各右移一格

  ;; 重叠合并 / 去重；primary 追到合并结果
  (define wo (window-set-selections ws (list (selection (point 0 0) (point 0 2))
                                             (selection (point 0 1) (point 0 3)))))
  (check-equal? (length (window-selections wo)) 1)
  (check-equal? (call-with-values (lambda () (selection-range (car (window-selections wo)))) list)
                (list (point 0 0) (point 0 3)))

  ;; 滚动 / 尺寸
  (check-equal? (window-top-line (window-scroll-clip w 2)) 2)
  (check-equal? (window-top-line (window-scroll-clip w -5)) 0)
  (check-equal? (window-top-line (window-set-top-line w 4)) 4)
  (check-equal? (window-left-col (window-hscroll (window-set-left-col w 3) 2)) 5)
  (check-equal? (window-set-size w 30 100) (window-set-size w 30 100))
  (check-equal? (window-mode (window-set-mode w 'wrap)) 'wrap)
  (check-equal? (window-top-seg (window-set-top-seg w 3)) 3)

  ;; 水平吸附：宽字符右半 → 下一字符起点；滚过行尾保留
  (define wd (window-open (buffer-open "中abc") 2 4))
  (check-equal? (window-left-col (window-set-left-col wd 0)) 0)
  (check-equal? (window-left-col (window-set-left-col wd 1)) 2)
  (check-equal? (window-left-col (window-set-left-col wd 2)) 2)
  (check-equal? (window-left-col (window-set-left-col wd 99)) 99)

  ;; 未知 mode → 报错
  (check-exn exn:fail? (lambda () (window-set-mode w 'bad)))

  (displayln "window.rkt: all tests passed"))
