#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "window.rkt" "render.rkt"
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
 window-clamp-view
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

;; 单元格累加器：chars 倒序累积 + width 缓存，避免逐字 string-append（O(L²)→O(L)）。
(struct cellrun (col face chars width) #:transparent)

(define (cellrun->run r)
  (run (cellrun-col r) (list->string (reverse (cellrun-chars r))) (cellrun-face r)))

(define (cells->runs cells)
  (define-values (runs cur)
    (for/fold ([runs '()] [cur #f])
              ([c (in-list cells)])
      (match-define (list col ch face) c)
      (cond
        [(and cur
              (equal? face (cellrun-face cur))
              (= (+ (cellrun-col cur) (cellrun-width cur)) col))
         (values runs
                 (struct-copy cellrun cur
                   [chars (cons ch (cellrun-chars cur))]
                   [width (+ (cellrun-width cur) (char-display-width ch))]))]
        [else
         (values (if cur (cons (cellrun->run cur) runs) runs)
                 (cellrun col face (list ch) (char-display-width ch)))])))
  (reverse (if cur (cons (cellrun->run cur) runs) runs)))

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
  (let loop ([line top-line]
             [segs (list->vector (wrap-segments (buffer-line-ref b top-line) width))]
             [seg top-seg]
             [row 0]
             [acc '()])
    (cond
      [(>= row height)
       (list->vector (reverse acc))]
      [(>= line (buffer-line-count b))
       (list->vector (append (reverse acc)
                             (for/list ([r (in-range row height)]) (vrow -1 0 0))))]
      [else
       (cond
         [(< seg (vector-length segs))
          (define s (vector-ref segs seg))
          (loop line segs (add1 seg) (add1 row)
                (cons (vrow line (car s) (cdr s)) acc))]
         [else
          (define next (add1 line))
          (if (>= next (buffer-line-count b))
              (list->vector (append (reverse acc)
                                    (for/list ([r (in-range row height)]) (vrow -1 0 0))))
              (loop next
                    (list->vector (wrap-segments (buffer-line-ref b next) width))
                    0 row acc))])])))

;;; ---------- 视口自洽（夹紧）----------

;; 视口视觉行数（mode-aware）：clip = buffer 行数；wrap = 折行段总数。
(define (visual-line-count w)
  (define b (window-buffer w))
  (case (window-mode w)
    ['clip (buffer-line-count b)]
    ['wrap (for/sum ([l (in-range (buffer-line-count b))])
             (length (wrap-segments (buffer-line-ref b l) (window-width w))))]
    [else (check-mode 'visual-line-count (window-mode w))]))

;; 把视口夹回合法域：`top`/`top-seg` 夹到范围内、`left-col` 吸附到字符起点。
;; **为什么必须有**：`rebase-free` 只改 point、`set-top/set-left/set-size` 只做 `max 0` ——
;; 另一个视图把内容删短（或几何变化）后，本视图的 top 会越界，实测后果是
;; clip 静默全空白 / wrap 在 `window->screen` 抛 vector-ref（ARCHITECTURE §10.3 D1）。
;; 语义修正：`free` 视图「视口钉住不动」= 钉住**但仍在合法域内**。
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

(define (window-vrows w)
  (define b (window-buffer w))
  (case (window-mode w)
    ['clip (layout-clip b (window-top-line w) (window-left-col w)
                        (window-width w) (window-height w))]
    ['wrap (layout-wrap b (window-top-line w) (window-top-seg w)
                        (window-width w) (window-height w))]
    [else (check-mode 'window-vrows (window-mode w))]))

;;; ---------- 光标 / 鼠标映射（共用 vrow 抽象）----------

;; vrow 是否是该 buffer 行在当前窗口里的最后一段（行尾归属判定）
(define (vrow-last-for-line? vrows row)
  (or (= row (sub1 (vector-length vrows)))
      (not (= (vrow-line (vector-ref vrows row))
              (vrow-line (vector-ref vrows (add1 row)))))))

;; point -> 屏幕 (row col)；不可见返回 (values #f #f)
(define (window-point->screen w)
  (define b (window-buffer w))
  (define p (window-point w))
  (define line (point-line p))
  (define target-col (index->column (buffer-line-ref b line) (point-col p)))
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
  (case (window-mode w)
    ['clip (window-scroll w delta)]
    ['wrap (window-scroll-wrap w delta)]
    [else (check-mode 'window-scroll-visual (window-mode w))]))

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
                            (max 0 (min target-col (- (+ target-col cw) width))))]
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
  (define p (window-point w))
  (define line (point-line p))
  (define target-col (index->column (buffer-line-ref b line) (point-col p)))
  (case (window-mode w)
    ['clip (ensure-clip w line target-col)]
    ['wrap (ensure-wrap w line target-col)]
    [else (check-mode 'window-ensure-point (window-mode w))]))

;;; ---------- 视觉行移动 ----------
;;; 上下键按「视觉行」移动：wrap 按折行段、clip 按 buffer 行，统一保持「视觉列」。
;;; 视觉列 = 光标在当前视觉行内的显示列偏移；目标视觉行更短时夹紧到行尾。

;; 一行在给定模式下的视觉段列表：clip = 单段 [0, 行宽)；wrap = wrap-segments。
(define (line-segments b line width mode)
  (define text (buffer-line-ref b line))
  (case mode
    ['clip (list (cons 0 (string-display-width text)))]
    ['wrap (wrap-segments text width)]
    [else (check-mode 'line-segments mode)]))

;; 把 (line, col) 沿视觉行移动 delta（-1 上 / +1 下），返回 (values 目标行 目标列)；
;; 无操作（已在首/末视觉行）返回 (values #f #f)。
(define (visual-move b line col width mode delta)
  (define n (buffer-line-count b))
  (define text (buffer-line-ref b line))
  (define dc (index->column text col))
  (define segs (line-segments b line width mode))
  (define-values (si seg-start) (segment-at segs dc))
  (define vc (- dc seg-start))
  ;; 目标段 = 一条 vrow（line + 显示列范围）
  (define target
    (cond
      [(< delta 0)
       (cond [(> si 0)
              (match-define (cons s e) (list-ref segs (sub1 si)))
              (vrow line s e)]
             [(> line 0)
              (match-define (cons s e) (last (line-segments b (sub1 line) width mode)))
              (vrow (sub1 line) s e)]
             [else #f])]
      [(> delta 0)
       (cond [(< si (sub1 (length segs)))
              (match-define (cons s e) (list-ref segs (add1 si)))
              (vrow line s e)]
             [(< line (sub1 n))
              (match-define (cons s e) (car (line-segments b (add1 line) width mode)))
              (vrow (add1 line) s e)]
             [else #f])]
      [else #f]))
  (cond
    [(not target) (values #f #f)]
    [else
     (define tl (vrow-line target))
     (define ts (vrow-start-col target))
     (define te (vrow-end-col target))
     (define tw (- te ts))
     (define ttext (buffer-line-ref b tl))
     (define line-width (string-display-width ttext))
     ;; 期望视觉列（先 clamp 到段宽），再右吸附到字符起点：落在宽字符右半格时前移、
     ;; 不往左退（否则 clip 模式光标会倒退一格并引起窗口左平移）。
     (define tdc-raw (+ ts (min vc tw)))
     (define tdc (snap-column-forward ttext tdc-raw))
     ;; tdc==te 有两个来源：clamp 到段尾，或段尾宽字符右半格被吸附。二者都取
     ;; 「段内最后一个字符」，保证不溢到下一视觉行（段边界渲染时归下一段）。
     (define tcol
       (if (and (= tdc te) (< te line-width))
           (column->index ttext (sub1 te))
           (column->index ttext tdc)))
     (values tl tcol)]))

;; 返回 point 已按视觉行移动的新 window（无操作时原样返回）。
(define (window-visual-move w delta)
  (define b (window-buffer w))
  (define p (window-point w))
  (define-values (l c)
    (visual-move b (point-line p) (point-col p)
                 (window-width w) (window-mode w) delta))
  (if l (window-set-point w (point l c)) w))

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
  (define w3 (window-goto (window-open b1 2 80) 1 1))
  (define-values (r c) (window-point->screen w3))
  (check-equal? (list r c) '(1 1))

  ;; 光标映射：wrap，point 在第二段起点
  (define w4 (window-goto ww 0 2))
  (define-values (r2 c2) (window-point->screen w4))
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
  (define w5-a (window-goto (window-open b5 2 10) 4 0))
  (check-equal? (window-top-line (window-ensure-point w5-a)) 3)   ; top = 4-2+1

  ;; 上方 → 置顶
  (define w5-b (window-goto (window-open b5 2 10) 0 0))
  (define wf2 (window-set-top w5-b 3))
  (check-equal? (window-top-line (window-ensure-point wf2)) 0)

  ;; 水平跟随 + 按行宽限位
  (define b6 (buffer-open "abcdefgh"))
  (define w6-a (window-goto (window-open b6 1 4) 0 7))
  (define whe (window-ensure-point w6-a))
  (check-equal? (window-left-col whe) 4)    ; 7-4+1=4，光标在右端
  (define w6-b (window-goto (window-open b6 1 4) 0 0))
  (define wh2s (window-set-left w6-b 4))
  (check-equal? (window-left-col (window-ensure-point wh2s)) 0)

  ;; 左右边界统一：宽字符绝不切半，右滚时左边界吸附到字符起点
  (define b8 (buffer-open "中中文中"))   ; 中中文中：列 0,2,4,6
  (define w8-a (window-goto (window-open b8 1 4) 0 2))
  (check-equal? (window-left-col (window-ensure-point w8-a)) 2)
  (define w8-b (window-goto (window-open b8 1 4) 0 1))
  (check-equal? (window-left-col (window-ensure-point w8-b)) 0)

  ;; 右边界：光标字符不再被丢弃（旧逻辑光标落在被丢弃的宽字符上）
  (define b9 (buffer-open "abcdef中"))   ; 列：a..f 0-5，中 [6,8)
  (define w9-a (window-goto (window-open b9 1 7) 0 6))
  (check-equal? (window-left-col (window-ensure-point w9-a)) 1)

  ;; 光标跟随（wrap）：下方 → 滚动一视觉行
  (define b7 (buffer-open "中中中\nx"))
  (define w7-a (window-goto (window-open b7 2 4) 1 0))
  (define wg (window-set-mode w7-a 'wrap))
  (define wge (window-ensure-point wg))
  (check-equal? (list (window-top-line wge) (window-top-seg wge)) '(0 1))

  ;; 视觉行移动（wrap）：同 buffer 行内跨折行段
  (define bv (buffer-open "中中中\nx"))       ; line0 宽6 折宽4 → 两段 [0,4) [4,6)
  (define wv (window-set-mode (window-open bv 3 4) 'wrap))
  (define wv1 (window-visual-move wv +1))       ; 段0 列0 → 段1 列0
  (check-equal? (window-point wv1) (point 0 2))
  (define wv2 (window-visual-move wv1 +1))      ; → 下一行
  (check-equal? (window-point wv2) (point 1 0))

  ;; 视觉列保持：段内列 1 → 目标行同列 1
  (define bv3 (buffer-open "abcd中\nxyz"))   ; line0 折宽3 → [0,3) [3,6)，中在段1列1
  (define wv3 (window-goto (window-set-mode (window-open bv3 2 3) 'wrap) 0 4))
  (define wv3-a (window-visual-move wv3 +1))
  (check-equal? (window-point wv3-a) (point 1 1))

  ;; 夹紧到段尾：目标段更短时不溢出到下一视觉行，停在段内最后一个字符
  (define bv4 (buffer-open "x\na中b"))        ; line1 折宽2 → [0,1) [1,3) [3,4)
  (define wv4 (window-goto (window-set-mode (window-open bv4 2 2) 'wrap) 0 1))
  (define wv4-a (window-visual-move wv4 +1))
  (check-equal? (window-point wv4-a) (point 1 0))        ; 停在 'a'，而非下一段 '中'

  ;; clip 模式也统一：按显示列（而非字符索引）保持视觉列
  (define bv5 (buffer-open "中ab\nabcd"))     ; 中占2列，'b' 在显示列3
  (define wv5 (window-goto (window-open bv5 2 80) 0 2))
  (define wv5-a (window-visual-move wv5 +1))
  (check-equal? (window-point wv5-a) (point 1 3))        ; 保持显示列3（旧逻辑会给字符列2）

  ;; 视觉列落在宽字符右半格 → 右吸附到下一字符起点，不往左退、不引起窗口左平移
  (define bv6 (buffer-open "abcd\n中中"))      ; line1 中[0,2) 中[2,4)
  (define wv6-g (window-set-left (window-open bv6 2 4) 1))   ; left=1
  (define wv6-g2 (window-goto wv6-g 0 1))       ; 光标 col1（窄字符，可视左边界）
  (define wv6-m (window-visual-move wv6-g2 +1))
  (check-equal? (window-point wv6-m) (point 1 1))           ; 吸附到 col2（第二中），而非 col0
  (define wv6-e (window-ensure-point wv6-m))
  (check-equal? (window-left-col wv6-e) 1)                   ; 窗口不左移

  ;; D1 回归：top 越界时 window-clamp-view 把视口夹回合法域
  ;; （原来 clip 静默全空白、wrap 在 window-vrows 抛 vector-ref）
  (define cv-b (buffer-open "l0\nl1\nl2\nl3"))
  (define cv-w (window-set-top (window-open cv-b 2 10) 50))
  (check-equal? (window-top-line cv-w) 50)          ; set-* 只做 max 0：夹紧时机在 document/投影前
  (define cv-c (window-clamp-view cv-w))
  (check-equal? (window-top-line cv-c) 2)           ; 4 行、高 2 → max-top = 2
  (check-equal? (vector-ref (window-vrows cv-c) 0) (vrow 2 0 10))   ; clip 的列范围 = 窗口宽度
  (define cv-cw (window-clamp-view (window-set-mode cv-w 'wrap)))
  (check-equal? (window-top-line cv-cw) 2)
  (check-true (vector? (window-vrows cv-cw)))
  ;; 未越界时不动；left-col 吸附到字符起点（宽字符右半 → 下一字符起点）
  (define cv-wb (window-open (buffer-open "中abc") 3 4))
  (check-equal? (window-clamp-view (window-set-top cv-wb 0)) (window-set-left cv-wb 0))
  (check-equal? (window-left-col (window-clamp-view (window-set-left cv-wb 1))) 2)

  (displayln "view.rkt: all tests passed"))
