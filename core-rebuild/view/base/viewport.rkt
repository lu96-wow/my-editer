#lang racket

(require "../../text/base/point.rkt" "../../text/base/track.rkt" "../../text/base/width.rkt"
         "layout.rkt")

;;; viewport.rkt —— 视口（纯显示，不含光标）
;;;
;;;   viewport = (top-line top-segment left-column width height mode line-numbers?)
;;; mode     : 'clip（不折行）| 'wrap（折行）
;;; top-line : 顶部 buffer 行
;;; top-segment  : wrap —— 顶部行的第几个折行段（clip 忽略）
;;; left-column : clip —— 水平滚动起始显示列（wrap 忽略）
;;; width/height : 可见列 / 行数（width 含行号栏）
;;; line-numbers? : 是否显示行号栏（栏宽/正文宽见 viewport-gutter-width）
;;;
;;; **光标/选区不属于视口**：它在 text/base/selection.rkt。视口 / 布局不认识光标；
;;; 需要光标的地方显式传入点（ensure / 上下移动）。

(provide
 ;; ---------- 类型 ----------
 (struct-out viewport)

 ;; ---------- 构造 ----------
 viewport-open

 ;; ---------- 设字段 ----------
 viewport-set-mode viewport-set-top-segment
 viewport-set-size viewport-set-top-line viewport-set-left-column viewport-set-line-numbers

 ;; ---------- 滚动 / ensure ----------
 viewport-scroll viewport-ensure

 ;; ---------- 派生 ----------
 viewport-vrows
 viewport-gutter-width viewport-content-width

 ;; ---------- 坐标换算 ----------
 viewport-point->screen-position viewport-point->screen-position/vrows
 viewport-screen-position->point viewport-screen-position->point/vrows

 ;; ---------- 锚点 / 镜像（视口间同步） ----------
 viewport-anchor viewport-set-anchor viewport-mirror

 ;; ---------- 视觉行上下 ----------
 point-up point-down)

(struct viewport (top-line top-segment left-column width height mode line-numbers?) #:transparent)

(define (check-mode who m)
  (unless (memq m '(clip wrap)) (error who "mode 必须是 'clip / 'wrap，得到 ~a" m)))

(define (viewport-open width height [mode 'clip] [line-numbers? #f])
  (check-mode 'viewport-open mode)
  (viewport 0 0 0 (max 1 width) (max 1 height) mode line-numbers?))

;;; ---------- 行号栏（gutter） ----------
;;; 行号栏是**显示装饰**：栏宽由当前视口「行号上界」推出（位数 + 1 分隔），
;;; 且不超过总宽减一（正文至少 1 列）。正文宽 = 总宽 − 栏宽。

(define (viewport-gutter-width t v)
  (cond
    [(not (viewport-line-numbers? v)) 0]
    [else
     (define last (min (track-length t) (+ (viewport-top-line v) (viewport-height v))))
     (min (+ (string-length (number->string (max 1 last))) 1)
          (max 0 (sub1 (viewport-width v))))]))

(define (viewport-content-width t v)
  (max 1 (- (viewport-width v) (viewport-gutter-width t v))))

;;; ---------- 改 ----------

(define (viewport-set-mode v m) (check-mode 'viewport-set-mode m) (struct-copy viewport v [mode m]))
(define (viewport-set-top-segment v n) (struct-copy viewport v [top-segment (max 0 n)]))
(define (viewport-set-size v w h) (struct-copy viewport v [width (max 1 w)] [height (max 1 h)]))
(define (viewport-set-top-line v n) (struct-copy viewport v [top-line (max 0 n)]))
(define (viewport-set-line-numbers v on?) (struct-copy viewport v [line-numbers? on?]))

;; 水平滚动（只 clip 有意义）：把列吸到参考（顶）行的字符起点。
;; **不夹到行尾** —— 超过行长时原样保留（滚过短行尾部合法）。
(define (snap-left t top-line L)
  (define s (track-ref t top-line))
  (if (<= L (string-display-width s)) (snap-display-column-forward s L) L))

(define (viewport-set-left-column t v n)
  (struct-copy viewport v [left-column (snap-left t (viewport-top-line v) (max 0 n))]))

;;; ---------- 竖直滚动（视觉行） ----------

(define (viewport-scroll t v delta)
  (case (viewport-mode v)
    [(clip) (struct-copy viewport v [top-line (max 0 (+ (viewport-top-line v) delta))])]
    [(wrap) (scroll-wrap t v delta)]
    [else (check-mode 'viewport-scroll (viewport-mode v))]))

(define (scroll-wrap t v delta)
  (define width (viewport-content-width t v))
  (define n (track-length t))
  (define (nseg line) (length (wrap-segments (track-ref t line) width)))
  ;; 其它视图的 top-line / top-segment 可能因文档变短（编辑 / undo）而越界 —— 先夹回合法域，
  ;; 否则 nseg / vrow-distance 会去 track-ref 一个不存在的行而崩。
  (define line0 (max 0 (min (viewport-top-line v) (sub1 n))))
  (define seg0 (if (= line0 (viewport-top-line v))
                   (min (viewport-top-segment v) (sub1 (nseg line0)))
                   0))
  (cond
    [(> delta 0)
     (let loop ([line line0] [seg seg0] [k delta])
       (cond
         [(or (<= k 0) (>= line n)) (struct-copy viewport v [top-line line] [top-segment seg])]
         [else
          (if (< (add1 seg) (nseg line))
              (loop line (add1 seg) (sub1 k))
              (loop (add1 line) 0 (sub1 k)))]))]
    [(< delta 0)
     (let loop ([line line0] [seg seg0] [k (- delta)])
       (cond
         [(<= k 0) (struct-copy viewport v [top-line line] [top-segment seg])]
         [(> seg 0) (loop line (sub1 seg) (sub1 k))]
         [(> line 0) (loop (sub1 line) (max 0 (sub1 (nseg (sub1 line)))) (sub1 k))]
         [else (struct-copy viewport v [top-line 0] [top-segment 0])]))]
    [else v]))

;;; ---------- 视口自洽 ----------

(define (viewport-vrows t v)
  (vrows t (viewport-top-line v) (viewport-top-segment v) (viewport-left-column v)
         (viewport-content-width t v) (viewport-height v) (viewport-mode v)))

;; 调整视口让 p 可见（必要时上下/左右滚动）。
(define (viewport-ensure t v p)
  (case (viewport-mode v)
    [(clip) (ensure-clip t v p)]
    [(wrap) (ensure-wrap t v p)]
    [else (check-mode 'viewport-ensure (viewport-mode v))]))

(define (ensure-clip t v p)
  (define n (track-length t))
  (define h (viewport-height v))
  (define l (point-line p))
  (define text (track-ref t l))
  (define dc (index->display-column text (point-column p)))
  ;; 光标字符宽度（行尾插入点算 1 格）：右滚要让它**整字**可见
  (define ci (display-column->index text dc))
  (define cw (if (= ci (string-length text)) 1 (char-display-width (string-ref text ci))))
  (define top (cond [(< l (viewport-top-line v)) l]
                    [(>= l (+ (viewport-top-line v) h)) (- l h -1)]
                    [else (viewport-top-line v)]))
  (define top* (max 0 (min top (max 0 (- n h)))))
  ;; 正文宽依赖 top-line（行号栏位数）：重算 top 后栏宽可能变，必须用**新顶行**的宽；
  ;; 否则左移/右滚会差一列（原先用旧宽会在换顶行后把光标挤出可视区）。
  (define v-top (struct-copy viewport v [top-line top*]))
  (define w (viewport-content-width t v-top))
  (define lc (viewport-left-column v))
  (define left (cond
                 [(< dc lc) dc]
                 [(> (+ dc cw) (+ lc w)) (max 0 (min dc (- (+ dc cw) w)))]
                 [else lc]))
  ;; 水平吸附必须用**光标所在行**（text）：顶行与光标行的宽字符边界不同，
  ;; 用顶行吸附会把 left-column 推过光标。
  (struct-copy viewport v-top [left-column (snap-left t l left)]))

;; 把 p 滚进可视区。wrap 下「栏宽 → 正文宽 → 折行 → 需要滚多少」互相依赖，
;; 用新宽重算直到稳定（行号位数最多变几次，收敛很快）。
(define (ensure-wrap t v p)
  (let loop ([v v] [k 0])
    (define width (viewport-content-width t v)) (define height (viewport-height v))
    (define l (point-line p))
    (define dc (index->display-column (track-ref t l) (point-column p)))
    (define seg (segment-index-of (track-ref t l) width 'wrap dc))
    (define top-line (viewport-top-line v)) (define top-segment (viewport-top-segment v))
    (cond
      [(< l top-line) (struct-copy viewport v [top-line l] [top-segment 0])]
      [(and (= l top-line) (< seg top-segment)) (struct-copy viewport v [top-segment seg])]
      [else
       (define dist (vrow-distance t width 'wrap top-line top-segment l seg))
       (cond
         [(< dist height) v]
         [(>= k 64) v]                       ; 保险：极端下仍不循环
         [else (loop (viewport-scroll t v (+ (- dist height) 1)) (add1 k))])])))

;; 一条视觉行是否是它那条 buffer 行在当前 vrows 里的最后一段（行尾归属）。
(define (vrow-last-for-line? vrows r)
  (or (= r (sub1 (vector-length vrows)))
      (not (= (vrow-line (vector-ref vrows r)) (vrow-line (vector-ref vrows (add1 r)))))))

;; p → 屏幕 (行, 列)（列含行号栏偏移）；不可见 → (values #f #f)。
;; /vrows 版：接收已算好的 vrows，不重复派生（多光标投影用）。
(define (viewport-point->screen-position/vrows t v vrows p)
  (define g (viewport-gutter-width t v))
  (define w (viewport-content-width t v))
  (case (viewport-mode v)
    [(clip)
     (define l (point-line p))
     (define dc (index->display-column (track-ref t l) (point-column p)))
     (define r (- l (viewport-top-line v)))
     (define c (- dc (viewport-left-column v)))
     (if (and (>= r 0) (< r (viewport-height v)) (>= c 0) (< c w))
         (values r (+ g c)) (values #f #f))]
    [(wrap)
     (define l (point-line p))
     (define dc (index->display-column (track-ref t l) (point-column p)))
     (let loop ([r 0])
       (cond
         [(>= r (vector-length vrows)) (values #f #f)]
         [else
          (define vr (vector-ref vrows r))
          (cond
            [(not (= (vrow-line vr) l)) (loop (add1 r))]
            [else
             (define s (vrow-start-column vr))
             (define e (vrow-end-column vr))
             (cond
               [(and (>= dc s) (< dc e)) (values r (+ g (- dc s)))]
               ;; 行尾插入点：落在最后一段的段尾且在正文宽内
               [(and (= dc e) (< (- dc s) w) (vrow-last-for-line? vrows r))
                (values r (+ g (- dc s)))]
               [else (loop (add1 r))])])]))]
    [else (check-mode 'viewport-point->screen-position/vrows (viewport-mode v))]))

(define (viewport-point->screen-position t v p)
  (viewport-point->screen-position/vrows t v (viewport-vrows t v) p))

;; 屏幕 (行, 列) → buffer 点；越界 / 屏幕行落在文末之后 → (values #f #f)。
;; 列含行号栏：col < 栏宽 → 一律视作正文列 0（点行号栏落到行首）。
;; /vrows 版：接收已算好的 vrows。
(define (viewport-screen-position->point/vrows t v vrows row col)
  (define g (viewport-gutter-width t v))
  (cond
    [(or (< row 0) (>= row (viewport-height v))) (values #f #f)]
    [else
     (define vr (vector-ref vrows row))
     (define line (vrow-line vr))
     (cond
       [(>= line (track-length t)) (values #f #f)]
       [else (values line
                     (display-column->index (track-ref t line)
                                            (+ (vrow-start-column vr) (max 0 (- col g)))))])]))

(define (viewport-screen-position->point t v row col)
  (viewport-screen-position->point/vrows t v (viewport-vrows t v) row col))

;;; ---------- 锚点（视口间同步） ----------
;;; 锚 = 可见区左上角的逻辑位置 (buffer 行, 显示列)。用**显示列而非字符索引**：
;;; clip 的 left-column 与 wrap 的段起点本来就是显示列，于是同一个锚能跨 mode 直接落位。
;;; 跨**文档**时文本不同，列需按锚行显示宽比例缩放（viewport-mirror）。
;;; 锚统一用**显示列**一种表示，省去字符索引 ↔ 列 ↔ 段号的来回换算。

;; 视口锚点。越界的 top-line / top-segment 先夹到合法域（软滚动可越过文末）。
(define (viewport-anchor t v)
  (define n (track-length t))
  (define line (max 0 (min (viewport-top-line v) (sub1 n))))
  (case (viewport-mode v)
    [(clip) (values line (viewport-left-column v))]
    [(wrap)
     (define segs (wrap-segments (track-ref t line) (viewport-content-width t v)))
     (define i (max 0 (min (viewport-top-segment v) (sub1 (length segs)))))
     (values line (car (list-ref segs i)))]
    [else (check-mode 'viewport-anchor (viewport-mode v))]))

;; 把视口锚点设到 (line, dc)，按**本视口自己的 mode** 落位（clip → left-column；wrap → top-segment）。
(define (viewport-set-anchor t v line dc)
  (define n (track-length t))
  (define l (max 0 (min (max 0 line) (sub1 n))))
  (define dc* (max 0 dc))
  (case (viewport-mode v)
    [(clip) (struct-copy viewport v [top-line l] [left-column (snap-left t l dc*)])]
    [(wrap) (struct-copy viewport v
                         [top-line l]
                         [top-segment (segment-index-of (track-ref t l) (viewport-content-width t v) 'wrap dc*)])]
    [else (check-mode 'viewport-set-anchor (viewport-mode v))]))

;; 跨文档投锚：行号固定（越界夹），列按**两侧锚行显示宽**比例缩放；源锚行为空 → 列 0。
;; **同文档不要用它** —— 精确取/放即可（见 sync 层）；空行上的软滚动列不应被比例抹成 0。
(define (viewport-mirror t-src src t-dst dst)
  (define-values (line dc) (viewport-anchor t-src src))
  (define ls (max 0 (min line (sub1 (track-length t-src)))))
  (define ld (max 0 (min line (sub1 (track-length t-dst)))))
  (define ws (string-display-width (track-ref t-src ls)))
  (define wd (string-display-width (track-ref t-dst ld)))
  (viewport-set-anchor t-dst dst line (if (zero? ws) 0 (round (* dc (/ wd ws))))))

;;; ---------- 上下（视觉行，随视口模式） ----------

(define (point-up t v p) (vrow-move t (viewport-content-width t v) (viewport-mode v) p -1))
(define (point-down t v p) (vrow-move t (viewport-content-width t v) (viewport-mode v) p +1))
