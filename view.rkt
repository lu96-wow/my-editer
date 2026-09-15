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
 window-scroll-visual
 window-ensure-point
 window-visual-move)

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
         (define cend (+ col (char-display-width ch)))
         (cond
           [(< cend start) (loop (add1 i) cend acc)]      ; 全在左界外
           [(>= col end) (reverse acc)]                    ; 已在右界外，停止
           ;; 跨边界（左/右统一）：字符未完整落在 [start,end) → 整字丢弃。
           ;; 绝不显示半个宽字符；左右边界同一规则，避免不一致。
           [(or (< col start) (> cend end)) (loop (add1 i) cend acc)]
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

;;; ---------- 光标跟随滚动 ----------
;;; 光标移出窗口边界时，调整窗口使其可见；左右按文本宽度限位。

(define (segment-at segs target-col)
  ;; segs 覆盖 [0, total)；返回 (values 段号 段起始列)
  (define n (length segs))
  (let loop ([i 0])
    (cond
      [(>= i (sub1 n))
       (define s (list-ref segs (sub1 n)))
       (values (sub1 n) (car s))]
      [else
       (define s (list-ref segs i))
       (if (and (<= (car s) target-col) (< target-col (cdr s)))
           (values i (car s))
           (loop (add1 i)))])))

(define (visual-distance b from-line from-seg to-line to-seg width)
  ;; 从 (from-line, from-seg) 到 (to-line, to-seg) 的视觉行数（to >= from）
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
  (define height (window-height w))
  (define width (window-width w))
  (define line-text (buffer-line-ref b line))
  ;; 光标所在字符的显示宽度；光标在行尾时是插入点，占 0 列。
  (define cw
    (let ([ci (column->index line-text target-col)])
      (if (= ci (string-length line-text)) 0
          (char-display-width (string-ref line-text ci)))))
  ;; 垂直
  (define top
    (cond [(< line (window-top-line w)) line]
          [(>= line (+ (window-top-line w) height)) (+ (- line height) 1)]
          [else (window-top-line w)]))
  (define max-top (max 0 (- (buffer-line-count b) height)))
  ;; 水平：视口必须完整包含光标字符（左右边界都不切字）。
  ;; 左界：光标列小于左界 → 左滚到光标列（本就是字符起点）；
  ;; 右界：光标字符右端超出右界 → 右滚并吸附到字符起点（消除左边界空格浮动）；
  ;; 视口内：left-col 保持不动——不因换行重吸附，避免上下移动时窗口左右平移。
  (define left
    (cond
      [(< target-col (window-left-col w)) target-col]
      [(> (+ target-col cw) (+ (window-left-col w) width))
       (snap-column-forward line-text
                            (max 0 (min target-col (+ target-col cw (- width)))))]
      [else (window-left-col w)]))
  (struct-copy window w
    [top-line (min (max 0 top) max-top)]
    [left-col left]))

(define (ensure-wrap w line target-col)
  (define b (window-buffer w))
  (define width (window-width w))
  (define height (window-height w))
  (define segs (wrap-segments (buffer-line-ref b line) width))
  (define-values (seg _) (segment-at segs target-col))
  (define top-line (window-top-line w))
  (define top-seg (window-top-seg w))
  (cond
    [(< line top-line)
     (struct-copy window w [top-line line] [top-seg 0])]
    [(and (= line top-line) (< seg top-seg))
     (struct-copy window w [top-seg seg])]
    [else
     (define dist (visual-distance b top-line top-seg line seg width))
     (if (< dist height)
         w
         (window-scroll-visual w (+ (- dist height) 1)))]))

(define (window-ensure-point w)
  (define b (window-buffer w))
  (define p (buffer-point b))
  (define line (cursor-line p))
  (define target-col (index->column (buffer-line-ref b line) (cursor-col p)))
  (case (window-mode w)
    ['clip (ensure-clip w line target-col)]
    ['wrap (ensure-wrap w line target-col)]
    [else (error 'window-ensure-point "unknown mode ~a" (window-mode w))]))

;;; ---------- 视觉行移动 ----------
;;; 上下键按「视觉行」移动：wrap 按折行段、clip 按 buffer 行，统一保持「视觉列」。
;;; 视觉列 = 光标在当前视觉行内的显示列偏移；目标视觉行更短时夹紧到行尾。

;; 一行在给定模式下的视觉段列表：clip = 单段 [0, 行宽)；wrap = wrap-segments。
(define (line-segments b line width mode)
  (define text (buffer-line-ref b line))
  (if (eq? mode 'clip)
      (list (cons 0 (string-display-width text)))
      (wrap-segments text width)))

;; 把 (line, col) 沿视觉行移动 delta（-1 上 / +1 下），返回 (values 目标行 目标列)；
;; 无操作（已在首/末视觉行）返回 (values #f #f)。
(define (visual-move b line col width mode delta)
  (define n (buffer-line-count b))
  (define text (buffer-line-ref b line))
  (define dc (index->column text col))
  (define segs (line-segments b line width mode))
  (define-values (si seg-start) (segment-at segs dc))
  (define vc (- dc seg-start))
  ;; 目标段（list 行号 起始列 结束列）
  (define target
    (cond
      [(< delta 0)
       (cond [(> si 0)
              (match-define (cons s e) (list-ref segs (sub1 si)))
              (list line s e)]
             [(> line 0)
              (match-define (cons s e) (last (line-segments b (sub1 line) width mode)))
              (list (sub1 line) s e)]
             [else #f])]
      [(> delta 0)
       (cond [(< si (sub1 (length segs)))
              (match-define (cons s e) (list-ref segs (add1 si)))
              (list line s e)]
             [(< line (sub1 n))
              (match-define (cons s e) (car (line-segments b (add1 line) width mode)))
              (list (add1 line) s e)]
             [else #f])]
      [else #f]))
  (cond
    [(not target) (values #f #f)]
    [else
     (define tl (car target))
     (define ts (cadr target))
     (define te (caddr target))
     (define tw (- te ts))
     (define ttext (buffer-line-ref b tl))
     (define line-width (string-display-width ttext))
     ;; 期望视觉列（先 clamp 到段宽）；落在宽字符右半格时右吸附到下一字符起点，
     ;; 不往左退——否则光标会倒退一个字符并导致窗口左平移（行首移动时尤其明显）。
     (define tdc-raw (+ ts (min vc tw)))
     (define tdc (snap-column-forward ttext tdc-raw))
     (define tcol
       (if (and (= tdc te) (< te line-width))
           (column->index ttext (sub1 te))   ; 夹紧到段尾：停在段内最后一个字符，不溢到下一视觉行
           (column->index ttext tdc)))
     (values tl tcol)]))

;; 返回 point 已按视觉行移动的新 buffer（无操作时原样返回）。
(define (window-visual-move w delta)
  (define b (window-buffer w))
  (define p (buffer-point b))
  (define-values (l c)
    (visual-move b (cursor-line p) (cursor-col p)
                 (window-width w) (window-mode w) delta))
  (if l (buffer-goto b l c) (values b #f)))

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
  (define-values (b3 _1) (buffer-goto b1 1 1))
  (define-values (r c) (window-point->screen (window-open b3 2 80)))
  (check-equal? (list r c) '(1 1))

  ;; 光标映射：wrap，point 在第二段起点
  (define-values (b4 _2) (buffer-goto b2 0 2))
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

  ;; 光标跟随（clip）：下方 → 窗口下移
  (define b5 (buffer-open "l1\nl2\nl3\nl4\nl5"))
  (define-values (b5-a _3) (buffer-goto b5 4 0))
  (define wf (window-open b5-a 2 10))
  (check-equal? (window-top-line (window-ensure-point wf)) 3)   ; top = 4-2+1

  ;; 上方 → 置顶
  (define-values (b5-b _4) (buffer-goto b5 0 0))
  (define wf2 (window-set-top (window-open b5-b 2 10) 3))
  (check-equal? (window-top-line (window-ensure-point wf2)) 0)

  ;; 水平跟随 + 按行宽限位
  (define b6 (buffer-open "abcdefgh"))
  (define-values (b6-a _5) (buffer-goto b6 0 7))
  (define whe (window-ensure-point (window-open b6-a 1 4)))
  (check-equal? (window-left-col whe) 4)    ; 7-4+1=4，光标在右端
  (define-values (b6-b _6) (buffer-goto b6 0 0))
  (define wh2s (window-set-left (window-open b6-b 1 4) 4))
  (check-equal? (window-left-col (window-ensure-point wh2s)) 0)

  ;; 左右边界统一：宽字符绝不切半，右滚时左边界吸附到字符起点
  (define b8 (buffer-open "中中文中"))   ; 中中文中：列 0,2,4,6
  ;; 光标在文（index2，col4）：右滚到 left=2（旧逻辑得 1 → 左边界空格浮动）
  (define-values (b8-a _8) (buffer-goto b8 0 2))
  (check-equal? (window-left-col (window-ensure-point (window-open b8-a 1 4))) 2)
  ;; 光标在第二个中（index1，col2）：视口内，left 不变
  (define-values (b8-b _9) (buffer-goto b8 0 1))
  (check-equal? (window-left-col (window-ensure-point (window-open b8-b 1 4))) 0)

  ;; 右边界：光标字符不再被丢弃（旧逻辑光标落在被丢弃的宽字符上）
  (define b9 (buffer-open "abcdef中"))   ; 列：a..f 0-5，中 [6,8)
  (define-values (b9-a _10) (buffer-goto b9 0 6))
  (check-equal? (window-left-col (window-ensure-point (window-open b9-a 1 7))) 1)

  ;; 光标跟随（wrap）：下方 → 滚动一视觉行
  (define b7 (buffer-open "中中中\nx"))
  (define-values (b7-a _7) (buffer-goto b7 1 0))
  (define wg (window-set-mode (window-open b7-a 2 4) 'wrap))
  (define wge (window-ensure-point wg))
  (check-equal? (list (window-top-line wge) (window-top-seg wge)) '(0 1))

  ;; 视觉行移动（wrap）：同 buffer 行内跨折行段
  (define bv (buffer-open "中中中\nx"))       ; line0 宽6 折宽4 → 两段 [0,4) [4,6)
  (define wv (window-set-mode (window-open bv 3 4) 'wrap))
  (define-values (bv1 _11) (window-visual-move wv +1))     ; 段0 列0 → 段1 列0
  (check-equal? (buffer-point bv1) (cursor 0 2))
  (define-values (bv2 _12) (window-visual-move (window-set-buffer wv bv1) +1))  ; → 下一行
  (check-equal? (buffer-point bv2) (cursor 1 0))

  ;; 视觉列保持：段内列 1 → 目标行同列 1
  (define bv3 (buffer-open "abcd中\nxyz"))   ; line0 折宽3 → [0,3) [3,6)，中在段1列1
  (define wv3 (window-set-mode (window-open bv3 2 3) 'wrap))
  (define-values (bv3-g _13) (buffer-goto bv3 0 4))
  (define-values (bv3-a _14) (window-visual-move (window-set-buffer wv3 bv3-g) +1))
  (check-equal? (buffer-point bv3-a) (cursor 1 1))

  ;; 夹紧到段尾：目标段更短时不溢出到下一视觉行，停在段内最后一个字符
  (define bv4 (buffer-open "x\na中b"))        ; line1 折宽2 → [0,1) [1,3) [3,4)
  (define wv4 (window-set-mode (window-open bv4 2 2) 'wrap))
  (define-values (bv4-g _15) (buffer-goto bv4 0 1))      ; line0 "x" 末尾，段内列1
  (define-values (bv4-a _16) (window-visual-move (window-set-buffer wv4 bv4-g) +1))
  (check-equal? (buffer-point bv4-a) (cursor 1 0))        ; 停在 'a'，而非下一段 '中'

  ;; clip 模式也统一：按显示列（而非字符索引）保持视觉列
  (define bv5 (buffer-open "中ab\nabcd"))     ; 中占2列，'b' 在显示列3
  (define-values (bv5-g _17) (buffer-goto bv5 0 2))
  (define-values (bv5-a _18) (window-visual-move (window-open bv5-g 2 80) +1))
  (check-equal? (buffer-point bv5-a) (cursor 1 3))        ; 保持显示列3（旧逻辑会给字符列2）

  ;; 视觉列落在宽字符右半格 → 右吸附到下一字符起点，不往左退、不引起窗口左平移
  (define bv6 (buffer-open "abcd\n中中"))      ; line1 中[0,2) 中[2,4)
  (define-values (bv6-g _19) (buffer-goto bv6 0 1))       ; 光标 col1（窄字符，可视左边界）
  (define wv6 (window-set-left (window-open bv6-g 2 4) 1))
  (define-values (bv6-m _20) (window-visual-move wv6 +1))
  (check-equal? (buffer-point bv6-m) (cursor 1 1))        ; 吸附到 col2（第二中），而非 col0
  (define wv6-e (window-ensure-point (window-set-buffer wv6 bv6-m)))
  (check-equal? (window-left-col wv6-e) 1)                ; 窗口不左移

  (displayln "view.rkt: all tests passed"))
