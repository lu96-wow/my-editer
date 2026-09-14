#lang racket

(require "cursor.rkt" "buffer.rkt" "window.rkt" "render.rkt"
         "width.rkt" "screen.rkt" rackunit)

;;; view.rkt —— 显示布局抽象
;;;
;;; 核心：vrow（视觉行）= 一条屏幕行对应的文本来源 (buffer行, 列范围)。
;;; 两种显示方式（clip 硬裁剪 / wrap 折行）只影响「如何生成 vrow 序列」，
;;; 之后的渲染（line-range->runs）、光标/鼠标映射、输出完全共用。

(provide
 (struct-out vrow)
 line-range->runs
 wrap-segments
 layout-clip
 layout-wrap
 window-vrows
 window-point->screen
 window-screen->point
 window-scroll-visual)

(struct vrow (line start-col end-col) #:transparent)
;; line      : buffer 行号（-1 = 空白行）
;; start-col : 该视觉行起始显示列（0-based，宽字符后）
;; end-col   : 结束显示列（不含）

;;; ---------- 共享：一行一段列范围 -> runs ----------

(define (line-range->runs b li start end)
  (define glyphs (rendered-line-glyphs (render-line b li)))
  (define n (vector-length glyphs))
  (define cells
    (let loop ([i 0] [col 0] [acc '()])
      (cond
        [(>= i n) (reverse acc)]
        [else
         (define g (vector-ref glyphs i))
         (define ch (glyph-ch g))
         (define face (glyph-face g))
         (define w (char-display-width ch))
         (define cend (+ col w))
         (cond
           [(< cend start) (loop (add1 i) cend acc)]               ; 全在左外
           [(>= col end) (reverse acc)]                            ; 已出右界
           [(and (< col start) (> w 1)) (loop (add1 i) cend acc)]  ; 宽字符左切，丢弃
           [(> cend end) (loop (add1 i) cend acc)]                 ; 宽字符右切，丢弃
           [else
            (loop (add1 i) cend
                  (cons (list (- col start) ch face) acc))])])))
  (cells->runs cells))

(define (cells->runs cells)
  (define-values (runs cur)
    (for/fold ([runs '()] [cur #f])
              ([c (in-list cells)])
      (match-define (list col ch face) c)
      (cond
        [(and cur
              (equal? face (run-face cur))
              (= (+ (run-col cur) (string-display-width (run-text cur))) col))
         (values runs (struct-copy run cur
                       [text (string-append (run-text cur) (string ch))]))]
        [else
         (values (if cur (cons cur runs) runs)
                 (run col (string ch) face))])))
  (reverse (if cur (cons cur runs) runs)))

;;; ---------- 折行边界 ----------
;;; text -> (listof (cons start-col end-col))，每段宽 <= width，
;;; 宽字符绝不切半（换段点只在字符边界），空行也返回一个 [0,0) 段。

(define (wrap-segments text width)
  (define n (string-length text))
  (define segs
    (let loop ([i 0] [col 0] [seg-start 0] [acc '()])
      (cond
        [(>= i n)
         (reverse (if (> col seg-start) (cons (cons seg-start col) acc) acc))]
        [else
         (define w (char-display-width (string-ref text i)))
         (cond
           [(zero? w)                           ; 组合字符：附着，不换段
            (loop (add1 i) col seg-start acc)]
           [(and (> col seg-start)              ; 段非空且放不下 → 换段
                 (> (+ (- col seg-start) w) width))
            (loop i col col (cons (cons seg-start col) acc))]
           [else                                ; 空段总是接受（单字符>width 也放）
            (loop (add1 i) (+ col w) seg-start acc)])])))
  (if (null? segs) (list (cons 0 0)) segs))

;;; ---------- 布局 ----------

(define (layout-clip b top-line left-col width height)
  (for/vector ([row (in-range height)])
    (define li (+ top-line row))
    (if (< li (buffer-line-count b))
        (vrow li left-col (+ left-col width))
        (vrow -1 0 0))))

(define (layout-wrap b top-line top-seg width height)
  (let loop ([line top-line] [seg top-seg] [row 0] [acc '()])
    (cond
      [(>= row height)
       (list->vector (reverse acc))]
      [(>= line (buffer-line-count b))
       (list->vector (append (reverse acc)
                             (for/list ([r (in-range row height)]) (vrow -1 0 0))))]
      [else
       (define segs (wrap-segments (buffer-line-ref b line) width))
       (define s (and (< seg (length segs)) (list-ref segs seg)))
       (if s
           (loop line (add1 seg) (add1 row) (cons (vrow line (car s) (cdr s)) acc))
           (loop (add1 line) 0 row acc))])))

(define (window-vrows w)
  (define b (window-buffer w))
  (case (window-mode w)
    ['clip (layout-clip b (window-top-line w) (window-left-col w)
                        (window-width w) (window-height w))]
    ['wrap (layout-wrap b (window-top-line w) (window-top-seg w)
                        (window-width w) (window-height w))]
    [else (error 'window-vrows "unknown mode ~a" (window-mode w))]))

;;; ---------- 光标 / 鼠标映射（共用 vrow 抽象）----------

;; vrow 是否是该 buffer 行在当前窗口里的最后一段（行尾归属判定）
(define (vrow-last-for-line? vrows row)
  (or (= row (sub1 (vector-length vrows)))
      (not (= (vrow-line (vector-ref vrows row))
              (vrow-line (vector-ref vrows (add1 row)))))))

;; point -> 屏幕 (row col)；不可见返回 (values #f #f)
(define (window-point->screen w)
  (define b (window-buffer w))
  (define p (buffer-point b))
  (define line (cursor-line p))
  (define target-col (index->column (buffer-line-ref b line) (cursor-col p)))
  (define vrows (window-vrows w))
  (let loop ([row 0])
    (cond
      [(>= row (vector-length vrows)) (values #f #f)]
      [else
       (define vr (vector-ref vrows row))
       (define hit?
         (and (= (vrow-line vr) line)
              (or (and (<= (vrow-start-col vr) target-col)
                       (< target-col (vrow-end-col vr)))
                  (and (= target-col (vrow-end-col vr))
                       (vrow-last-for-line? vrows row)))))
       (if hit?
           (values row (- target-col (vrow-start-col vr)))
           (loop (add1 row)))])))

;; 屏幕 (row col) -> buffer (line col)；越界返回 (values #f #f)
(define (window-screen->point w row col)
  (define vrows (window-vrows w))
  (cond
    [(or (< row 0) (>= row (vector-length vrows)))
     (values #f #f)]
    [else
     (define vr (vector-ref vrows row))
     (if (< (vrow-line vr) 0)
         (values #f #f)
         (let ([text (buffer-line-ref (window-buffer w) (vrow-line vr))])
           (values (vrow-line vr)
                   (column->index text (+ (vrow-start-col vr) col)))))]))

;;; ---------- 视觉行滚动 ----------

(define (window-scroll-visual w delta)
  (if (eq? (window-mode w) 'clip)
      (window-scroll w delta)
      (window-scroll-wrap w delta)))

(define (window-scroll-wrap w delta)
  (define b (window-buffer w))
  (define width (window-width w))
  (define (nseg line)
    (length (wrap-segments (buffer-line-ref b line) width)))
  (cond
    [(> delta 0)
     (let loop ([line (window-top-line w)] [seg (window-top-seg w)] [k delta])
       (cond
         [(or (<= k 0) (>= line (buffer-line-count b)))
          (struct-copy window w [top-line line] [top-seg seg])]
         [else
          (define s (nseg line))
          (if (< (add1 seg) s)
              (loop line (add1 seg) (sub1 k))
              (loop (add1 line) 0 (sub1 k)))]))]
    [(< delta 0)
     (let loop ([line (window-top-line w)] [seg (window-top-seg w)] [k (- delta)])
       (cond
         [(<= k 0)
          (struct-copy window w [top-line line] [top-seg seg])]
         [else
          (cond
            [(> seg 0) (loop line (sub1 seg) (sub1 k))]
            [(> line 0) (loop (sub1 line) (max 0 (sub1 (nseg (sub1 line)))) (sub1 k))]
            [else (struct-copy window w [top-line 0] [top-seg 0])])]))]
    [else w]))

(module+ test
  ;; line-range->runs：宽字符 + 裁剪
  (define b0 (buffer-open "a中b\nc"))
  (check-equal? (line-range->runs b0 0 0 10)
                (list (run 0 "a中b" (hash))))
  (check-equal? (line-range->runs b0 0 2 10)
                (list (run 1 "b" (hash))))          ; left=2，宽字符被切丢，b 在列 1

  ;; wrap-segments
  (check-equal? (wrap-segments "aaaa中中中" 5) '((0 . 4) (4 . 8) (8 . 10)))
  (check-equal? (wrap-segments "中" 1) '((0 . 2)))
  (check-equal? (wrap-segments "" 5) '((0 . 0)))

  ;; clip 布局
  (define b1 (buffer-open "l1\nl2\nl3"))
  (define wc (window-open b1 2 80))
  (check-equal? (map (lambda (v) (list (vrow-line v) (vrow-start-col v)))
                     (vector->list (window-vrows wc)))
                '((0 0) (1 0)))

  ;; wrap 布局："中中中"（宽 6）折宽 4 → 两段 + 下一行
  (define b2 (buffer-open "中中中\nx"))
  (define ww (window-set-mode (window-open b2 3 4) 'wrap))
  (check-equal? (map (lambda (v) (list (vrow-line v) (vrow-start-col v) (vrow-end-col v)))
                     (vector->list (window-vrows ww)))
                '((0 0 4) (0 4 6) (1 0 1)))

  ;; 光标映射：clip
  (define b3 (buffer-goto b1 1 1))
  (define-values (r c) (window-point->screen (window-open b3 2 80)))
  (check-equal? (list r c) '(1 1))

  ;; 光标映射：wrap，point 在第二段起点
  (define b4 (buffer-goto b2 0 2))
  (define-values (r2 c2) (window-point->screen (window-set-buffer ww b4)))
  (check-equal? (list r2 c2) '(1 0))

  ;; 鼠标映射：wrap，点第二段第 0 列 → 回到 line 0 col 2
  (define-values (l3 c3) (window-screen->point ww 1 0))
  (check-equal? (list l3 c3) '(0 2))

  ;; wrap 视觉行滚动
  (define ww2 (window-scroll-visual ww 1))
  (check-equal? (list (window-top-line ww2) (window-top-seg ww2)) '(0 1))
  (define ww3 (window-scroll-visual ww2 1))
  (check-equal? (list (window-top-line ww3) (window-top-seg ww3)) '(1 0))
  (define ww4 (window-scroll-visual ww3 -1))
  (check-equal? (list (window-top-line ww4) (window-top-seg ww4)) '(0 1))

  (displayln "view.rkt: all tests passed"))
