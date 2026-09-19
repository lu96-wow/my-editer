#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "window.rkt" "render.rkt"
         "width.rkt" "screen.rkt" rackunit)

;;; view.rkt —— 显示布局：vrow（视觉行）
;;;
;;; vrow = 一条屏幕行对应的文本来源 (buffer行, 显示列范围)。两种显示方式只影响
;;; 「怎么生成 vrow 序列」，之后的渲染、光标/鼠标映射、滚动完全共用：
;;;   clip：一条 buffer 行 = 一条 vrow，列范围 = [left-col, left-col+width)
;;;   wrap：一条 buffer 行 = 若干段，每段宽 ≤ width，宽字符绝不切半
;;;
;;; 列一律是**显示列**（width 换算后）；point 的 col 是字符索引，映射时换算。

(provide
 (struct-out vrow)
 line-range->runs
 wrap-segments
 layout-clip
 layout-wrap
 window-vrows
 window-point->screen
 window-screen->point
 window-scroll-visual
 window-ensure-point
 window-clamp-view
 window-visual-move
 window-up
 window-down)

(struct vrow (line start-col end-col) #:transparent)
;; line      : buffer 行号（-1 = 空白行）
;; start-col : 起始显示列（0-based）
;; end-col   : 结束显示列（不含）

;;; ---------- 一行 [start,end) 显示列 → runs ----------

(define (line-range->runs b li start end)
  (define glyphs (rendered-line-glyphs (render-line b li)))
  (define n (vector-length glyphs))
  (define cells
    (let loop ([i 0] [col 0] [acc '()])
      (cond
        [(>= i n) (reverse acc)]
        [else
         (define g (vector-ref glyphs i))
         (define ch (glyph-ch g)) (define face (glyph-face g))
         (define cend (+ col (char-display-width ch)))
         (cond
           [(< cend start) (loop (add1 i) cend acc)]        ; 全在左界之外
           [(>= col end) (reverse acc)]                     ; 已到右界之外
           ;; 跨任意边界（左右同一规则）：字符未完整落在 [start,end) → 整字丢弃。
           [(or (< col start) (> cend end)) (loop (add1 i) cend acc)]
           [else (loop (add1 i) cend (cons (list (- col start) ch face) acc))])])))
  (cells->runs cells))

(struct cellrun (col face chars width) #:transparent)

(define (cellrun->run r)
  (run (cellrun-col r) (list->string (reverse (cellrun-chars r))) (cellrun-face r)))

(define (cells->runs cells)
  (define-values (runs cur)
    (for/fold ([runs '()] [cur #f]) ([c (in-list cells)])
      (match-define (list col ch face) c)
      (cond
        [(and cur (equal? face (cellrun-face cur))
              (= (+ (cellrun-col cur) (cellrun-width cur)) col))
         (values runs (struct-copy cellrun cur
                        [chars (cons ch (cellrun-chars cur))]
                        [width (+ (cellrun-width cur) (char-display-width ch))]))]
        [else
         (values (if cur (cons (cellrun->run cur) runs) runs)
                 (cellrun col face (list ch) (char-display-width ch)))])))
  (reverse (if cur (cons (cellrun->run cur) runs) runs)))

;;; ---------- 折行边界 ----------
;; text → (listof (cons start-col end-col))，每段宽 ≤ width，宽字符绝不切半；空行给一段 [0,0)。

(define (wrap-segments text width)
  (define n (string-length text))
  (define segs
    (let loop ([i 0] [col 0] [seg-start 0] [acc '()])
      (cond
        [(>= i n) (reverse (if (> col seg-start) (cons (cons seg-start col) acc) acc))]
        [else
         (define w (char-display-width (string-ref text i)))
         (cond
           [(zero? w) (loop (add1 i) col seg-start acc)]          ; 组合字符附着
           [(and (> col seg-start) (> (+ (- col seg-start) w) width))
            (loop i col col (cons (cons seg-start col) acc))]     ; 放不下 → 换段
           [else (loop (add1 i) (+ col w) seg-start acc)])])))    ; 空段总接受（单字>width也放）
  (if (null? segs) (list (cons 0 0)) segs))

;;; ---------- 布局 ----------

(define (layout-clip b top-line left-col width height)
  (for/vector ([row (in-range height)])
    (define li (+ top-line row))
    (if (< li (buffer-line-count b))
        (vrow li left-col (+ left-col width))
        (vrow -1 0 0))))

(define (layout-wrap b top-line top-seg width height)
  (let loop ([line top-line]
             [segs (list->vector (wrap-segments (buffer-line-ref b top-line) width))]
             [seg top-seg] [row 0] [acc '()])
    (cond
      [(>= row height) (list->vector (reverse acc))]
      [(>= line (buffer-line-count b))
       (list->vector (append (reverse acc)
                             (for/list ([r (in-range row height)]) (vrow -1 0 0))))]
      [else
       (cond
         [(< seg (vector-length segs))
          (define s (vector-ref segs seg))
          (loop line segs (add1 seg) (add1 row) (cons (vrow line (car s) (cdr s)) acc))]
         [else
          (define next (add1 line))
          (if (>= next (buffer-line-count b))
              (list->vector (append (reverse acc)
                                    (for/list ([r (in-range row height)]) (vrow -1 0 0))))
              (loop next (list->vector (wrap-segments (buffer-line-ref b next) width))
                    0 row acc))])])))

(define (window-vrows w)
  (define b (window-buffer w))
  (case (window-mode w)
    ['clip (layout-clip b (window-top-line w) (window-left-col w)
                        (window-width w) (window-height w))]
    ['wrap (layout-wrap b (window-top-line w) (window-top-seg w)
                        (window-width w) (window-height w))]
    [else (check-mode 'window-vrows (window-mode w))]))

;;; ---------- 视口自洽（夹紧）----------

;; mode-aware 的视觉行总数：clip = buffer 行数；wrap = 折行段总数。
(define (visual-line-count w)
  (define b (window-buffer w))
  (case (window-mode w)
    ['clip (buffer-line-count b)]
    ['wrap (for/sum ([l (in-range (buffer-line-count b))])
             (length (wrap-segments (buffer-line-ref b l) (window-width w))))]
    [else (check-mode 'visual-line-count (window-mode w))]))

;; 把视口夹回合法域：top/top-seg 在范围内、left-col 吸附到字符起点。
;; free 视图「视口钉住」= 钉住**但仍在合法域内**；否则别的视图删短内容后
;; clip 会静默全空白、wrap 会抛 vector-ref。
(define (window-clamp-view w)
  (define b (window-buffer w))
  (define n (buffer-line-count b))
  (define max-top (max 0 (- (visual-line-count w) (window-height w))))
  (define top (max 0 (min (window-top-line w) max-top)))
  (define tline (max 0 (min top (sub1 n))))
  (define ttext (buffer-line-ref b tline))
  (define max-seg (case (window-mode w)
                    ['clip 0]
                    ['wrap (max 0 (sub1 (length (wrap-segments ttext (window-width w)))))]
                    [else (check-mode 'window-clamp-view (window-mode w))]))
  (struct-copy window w
    [top-line top]
    [top-seg (max 0 (min (window-top-seg w) max-seg))]
    [left-col (snap-left-col ttext (window-left-col w))]))

;;; ---------- 光标 / 鼠标映射 ----------

;; vrow 是否是它那条 buffer 行在当前窗口里的最后一段（行尾归属）
(define (vrow-last-for-line? vrows row)
  (or (= row (sub1 (vector-length vrows)))
      (not (= (vrow-line (vector-ref vrows row))
              (vrow-line (vector-ref vrows (add1 row)))))))

;; point → 屏幕 (row col)；不可见 → (values #f #f)
(define (window-point->screen w)
  (define b (window-buffer w))
  (define p (window-point w))
  (define line (point-line p))
  (define target (index->column (buffer-line-ref b line) (point-col p)))
  (define vrows (window-vrows w))
  (let loop ([row 0])
    (cond
      [(>= row (vector-length vrows)) (values #f #f)]
      [else
       (define vr (vector-ref vrows row))
       (define hit? (and (= (vrow-line vr) line)
                         (or (and (<= (vrow-start-col vr) target) (< target (vrow-end-col vr)))
                             (and (= target (vrow-end-col vr))
                                  (vrow-last-for-line? vrows row)))))
       (if hit? (values row (- target (vrow-start-col vr))) (loop (add1 row)))])))

;; 屏幕 (row col) → buffer (line col)；越界 → (values #f #f)
(define (window-screen->point w row col)
  (define vrows (window-vrows w))
  (cond
    [(or (< row 0) (>= row (vector-length vrows))) (values #f #f)]
    [else
     (define vr (vector-ref vrows row))
     (if (< (vrow-line vr) 0)
         (values #f #f)
         (values (vrow-line vr)
                 (column->index (buffer-line-ref (window-buffer w) (vrow-line vr))
                                (+ (vrow-start-col vr) col))))]))

;;; ---------- 视觉行滚动 ----------

(define (window-scroll-visual w delta)
  (case (window-mode w)
    ['clip (window-scroll w delta)]
    ['wrap (window-scroll-wrap w delta)]
    [else (check-mode 'window-scroll-visual (window-mode w))]))

(define (window-scroll-wrap w delta)
  (define b (window-buffer w))
  (define width (window-width w))
  (define (nseg line) (length (wrap-segments (buffer-line-ref b line) width)))
  (cond
    [(> delta 0)
     (let loop ([line (window-top-line w)] [seg (window-top-seg w)] [k delta])
       (cond
         [(or (<= k 0) (>= line (buffer-line-count b)))
          (struct-copy window w [top-line line] [top-seg seg])]
         [else
          (define s (nseg line))
          (if (< (add1 seg) s) (loop line (add1 seg) (sub1 k))
              (loop (add1 line) 0 (sub1 k)))]))]
    [(< delta 0)
     (let loop ([line (window-top-line w)] [seg (window-top-seg w)] [k (- delta)])
       (cond
         [(<= k 0) (struct-copy window w [top-line line] [top-seg seg])]
         [else
          (cond
            [(> seg 0) (loop line (sub1 seg) (sub1 k))]
            [(> line 0) (loop (sub1 line) (max 0 (sub1 (nseg (sub1 line)))) (sub1 k))]
            [else (struct-copy window w [top-line 0] [top-seg 0])])]))]
    [else w]))

;;; ---------- 光标跟随滚动 ----------

(define (segment-at segs target-col)
  (define n (length segs))
  (let loop ([i 0])
    (cond
      [(>= i (sub1 n)) (values (sub1 n) (car (list-ref segs (sub1 n))))]
      [else
       (define s (list-ref segs i))
       (if (and (<= (car s) target-col) (< target-col (cdr s)))
           (values i (car s))
           (loop (add1 i)))])))

(define (visual-distance b from-line from-seg to-line to-seg width)
  (cond
    [(> from-line to-line) 0]
    [(= from-line to-line) (- to-seg from-seg)]
    [else
     (+ (- (length (wrap-segments (buffer-line-ref b from-line) width)) from-seg)
        (for/sum ([l (in-range (add1 from-line) to-line)])
          (length (wrap-segments (buffer-line-ref b l) width)))
        to-seg)]))

(define (ensure-clip w line target-col)
  (define b (window-buffer w))
  (define height (window-height w)) (define width (window-width w))
  (define text (buffer-line-ref b line))
  (define cw (let ([ci (column->index text target-col)])
               (if (= ci (string-length text)) 0
                   (char-display-width (string-ref text ci)))))
  (define top (cond [(< line (window-top-line w)) line]
                    [(>= line (+ (window-top-line w) height)) (+ (- line height) 1)]
                    [else (window-top-line w)]))
  (define max-top (max 0 (- (buffer-line-count b) height)))
  (define left
    (cond
      [(< target-col (window-left-col w)) target-col]
      [(> (+ target-col cw) (+ (window-left-col w) width))
       (snap-column-forward text (max 0 (min target-col (- (+ target-col cw) width))))]
      [else (window-left-col w)]))
  (struct-copy window w [top-line (min (max 0 top) max-top)] [left-col left]))

(define (ensure-wrap w line target-col)
  (define b (window-buffer w))
  (define width (window-width w)) (define height (window-height w))
  (define segs (wrap-segments (buffer-line-ref b line) width))
  (define-values (seg _) (segment-at segs target-col))
  (define top-line (window-top-line w)) (define top-seg (window-top-seg w))
  (cond
    [(< line top-line) (struct-copy window w [top-line line] [top-seg 0])]
    [(and (= line top-line) (< seg top-seg)) (struct-copy window w [top-seg seg])]
    [else
     (define dist (visual-distance b top-line top-seg line seg width))
     (if (< dist height) w (window-scroll-visual w (+ (- dist height) 1)))]))

(define (window-ensure-point w)
  (define b (window-buffer w))
  (define p (window-point w))
  (define line (point-line p))
  (define target (index->column (buffer-line-ref b line) (point-col p)))
  (case (window-mode w)
    ['clip (ensure-clip w line target)]
    ['wrap (ensure-wrap w line target)]
    [else (check-mode 'window-ensure-point (window-mode w))]))

;;; ---------- 视觉行移动 ----------
;; 上下键按**视觉行**移动：clip 按 buffer 行、wrap 按折行段，统一保持「视觉列」。

(define (line-segments b line width mode)
  (define text (buffer-line-ref b line))
  (case mode
    ['clip (list (cons 0 (string-display-width text)))]
    ['wrap (wrap-segments text width)]
    [else (check-mode 'line-segments mode)]))

(define (visual-move b line col width mode delta)
  (define n (buffer-line-count b))
  (define text (buffer-line-ref b line))
  (define dc (index->column text col))
  (define segs (line-segments b line width mode))
  (define-values (si seg-start) (segment-at segs dc))
  (define vc (- dc seg-start))
  (define target
    (cond
      [(< delta 0)
       (cond [(> si 0) (match-define (cons s e) (list-ref segs (sub1 si))) (vrow line s e)]
             [(> line 0) (match-define (cons s e) (last (line-segments b (sub1 line) width mode)))
                         (vrow (sub1 line) s e)]
             [else #f])]
      [(> delta 0)
       (cond [(< si (sub1 (length segs))) (match-define (cons s e) (list-ref segs (add1 si))) (vrow line s e)]
             [(< line (sub1 n)) (match-define (cons s e) (car (line-segments b (add1 line) width mode)))
                                (vrow (add1 line) s e)]
             [else #f])]
      [else #f]))
  (cond
    [(not target) (values #f #f)]
    [else
     (define tl (vrow-line target)) (define ts (vrow-start-col target)) (define te (vrow-end-col target))
     (define tw (- te ts))
     (define ttext (buffer-line-ref b tl))
     (define line-width (string-display-width ttext))
     (define tdc (snap-column-forward ttext (+ ts (min vc tw))))
     ;; tdc == te 有两个来源：夹到段尾，或段尾宽字符右半格被吸附。都取段内最后一个字符。
     (define tcol (if (and (= tdc te) (< te line-width))
                      (column->index ttext (sub1 te))
                      (column->index ttext tdc)))
     (values tl tcol)]))

(define (window-visual-move w delta)
  (define b (window-buffer w))
  (define p (window-point w))
  (define-values (l c) (visual-move b (point-line p) (point-col p)
                                    (window-width w) (window-mode w) delta))
  (if l (window-set-point w (point l c)) w))

(define (window-up w)   (window-visual-move w -1))
(define (window-down w) (window-visual-move w +1))

;;; ---------- 测试 ----------

(module+ test
  ;; line-range->runs：宽字符 + 裁剪
  (define b0 (buffer-open "a中b\nc"))
  (check-equal? (line-range->runs b0 0 0 10) (list (run 0 "a中b" (hash))))
  (check-equal? (line-range->runs b0 0 2 10) (list (run 1 "b" (hash))))   ; 左界切丢「中」

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

  ;; wrap 布局
  (define ww (window-set-mode (window-open (buffer-open "中中中\nx") 3 4) 'wrap))
  (check-equal? (map (lambda (v) (list (vrow-line v) (vrow-start-col v) (vrow-end-col v)))
                     (vector->list (window-vrows ww)))
                '((0 0 4) (0 4 6) (1 0 1)))

  ;; 光标映射
  (check-equal? (call-with-values (lambda () (window-point->screen (window-goto (window-open b1 2 80) 1 1))) list)
                '(1 1))
  (check-equal? (call-with-values (lambda () (window-point->screen (window-goto ww 0 2))) list)
                '(1 0))
  (check-equal? (call-with-values (lambda () (window-screen->point ww 1 0)) list)
                '(0 2))

  ;; wrap 视觉行滚动
  (check-equal? (let ([w (window-scroll-visual ww 1)]) (list (window-top-line w) (window-top-seg w))) '(0 1))
  (check-equal? (let* ([w (window-scroll-visual ww 1)] [w (window-scroll-visual w 1)])
                  (list (window-top-line w) (window-top-seg w))) '(1 0))
  (check-equal? (let* ([w (window-scroll-visual ww 2)] [w (window-scroll-visual w -1)])
                  (list (window-top-line w) (window-top-seg w))) '(0 1))

  ;; 光标跟随（clip）
  (define b5 (buffer-open "l1\nl2\nl3\nl4\nl5"))
  (check-equal? (window-top-line (window-ensure-point (window-goto (window-open b5 2 10) 4 0))) 3)
  (check-equal? (window-top-line (window-ensure-point (window-set-top (window-goto (window-open b5 2 10) 0 0) 3))) 0)
  ;; 水平跟随
  (check-equal? (window-left-col (window-ensure-point (window-goto (window-open (buffer-open "abcdefgh") 1 4) 0 7))) 4)
  (check-equal? (window-left-col (window-ensure-point (window-set-left (window-goto (window-open (buffer-open "abcdefgh") 1 4) 0 0) 4))) 0)

  ;; 宽字符边界：绝不切半
  (check-equal? (window-left-col (window-ensure-point (window-goto (window-open (buffer-open "中中文中") 1 4) 0 2))) 2)
  (check-equal? (window-left-col (window-ensure-point (window-goto (window-open (buffer-open "abcdef中") 1 7) 0 6))) 1)

  ;; 光标跟随（wrap）
  (define w7 (window-set-mode (window-goto (window-open (buffer-open "中中中\nx") 2 4) 1 0) 'wrap))
  (check-equal? (let ([w (window-ensure-point w7)]) (list (window-top-line w) (window-top-seg w))) '(0 1))

  ;; 视觉行移动（wrap 跨段）
  (define wv (window-set-mode (window-open (buffer-open "中中中\nx") 3 4) 'wrap))
  (check-equal? (window-point (window-visual-move wv +1)) (point 0 2))
  (check-equal? (window-point (window-visual-move (window-visual-move wv +1) +1)) (point 1 0))
  ;; 视觉列保持（clip 按显示列）
  (check-equal? (window-point (window-visual-move (window-goto (window-open (buffer-open "中ab\nabcd") 2 80) 0 2) +1))
                (point 1 3))
  ;; 夹到段尾不溢出
  (check-equal? (window-point (window-visual-move (window-goto (window-set-mode (window-open (buffer-open "x\na中b") 2 2) 'wrap) 0 1) +1))
                (point 1 0))

  ;; clamp-view
  (define cv (window-set-top (window-open (buffer-open "l0\nl1\nl2\nl3") 2 10) 50))
  (check-equal? (window-top-line cv) 50)                 ; set-* 只做 max 0
  (check-equal? (window-top-line (window-clamp-view cv)) 2)
  (check-equal? (vector-ref (window-vrows (window-clamp-view cv)) 0) (vrow 2 0 10))
  (check-true (vector? (window-vrows (window-clamp-view (window-set-mode cv 'wrap)))))
  (check-equal? (window-left-col (window-clamp-view (window-set-left (window-open (buffer-open "中abc") 3 4) 1))) 2)

  (displayln "view.rkt: all tests passed"))
