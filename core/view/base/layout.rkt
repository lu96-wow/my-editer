#lang racket

(require "../../text/base/track.rkt" "../../text/base/line.rkt" "../../text/base/point.rkt" "../../text/base/width.rkt")

;;; layout.rkt —— 布局：buffer 行 ↔ 屏幕行
;;;
;;; 两种模式只影响「一行怎么切成视觉行」：
;;;   clip  一条 buffer 行 = 一条视觉行（列按 left-column 平移）
;;;   wrap  一条 buffer 行 = 若干折行段（每段宽 ≤ width）
;;; 之后的光标映射、上下移动、滚动都共用同一套「视觉行」算子。
;;;
;;; 纯函数：参数显式（track / width / mode …），不认识 viewport。

(provide
 ;; ---------- 类型 ----------
 (struct-out vrow)

 ;; ---------- 折行 / 段 ----------
 wrap-segments segments-of-line segment-index-of

 ;; ---------- 视觉行 ----------
 vrows vrow-distance vrow-move)

;; 一条视觉行的来源：(buffer 行, 显示列范围 [start-column,end-column))。
(struct vrow (line start-column end-column) #:transparent)

;; 把一行按显示宽 width 切成折行段，返回 (listof (cons start-column end-column))，每段宽 ≤ width。
;; 空行给一段 [0,0)；末段正好填满 width 时补一个空段（行尾插入点占一个视觉行）。
(define (wrap-segments text width)
  (define n (string-length text))
  (define segs
    (let loop ([i 0] [col 0] [seg-start 0] [acc '()])
      (cond
        [(>= i n) (reverse (if (> col seg-start) (cons (cons seg-start col) acc) acc))]
        [else
         (define w (char-display-width (string-ref text i)))
         (cond
           [(zero? w) (loop (add1 i) col seg-start acc)]           ; 组合字符附着
           [(and (> col seg-start) (> (+ (- col seg-start) w) width))
            (loop i col col (cons (cons seg-start col) acc))]     ; 放不下 → 换段
           [else (loop (add1 i) (+ col w) seg-start acc)])])))     ; 空段总接受（单字>width也放）
  (cond
    [(null? segs) (list (cons 0 0))]
    [else
     (define last-segment (last segs))
     (if (= (- (cdr last-segment) (car last-segment)) width)
         (append segs (list (cons (cdr last-segment) (cdr last-segment))))
         segs)]))

;; 一行的视觉段（display-column 半开区间）：clip → 整行一段；wrap → 折行段。
(define (segments-of-line text width mode)
  (case mode
    [(clip) (list (cons 0 (string-display-width text)))]
    [(wrap) (wrap-segments text width)]
    [else (error 'segments-of-line "mode 必须是 'clip / 'wrap，得到 ~a" mode)]))

(define (segment-count text width mode) (length (segments-of-line text width mode)))

;; dc 落在第几段（wrap 下不在任何段内 → 末段）。
(define (segment-index-of text width mode dc)
  (case mode
    [(clip) 0]
    [(wrap)
     (define segs (wrap-segments text width))
     (or (for/first ([s (in-list segs)] [i (in-naturals)]
                     #:when (and (<= (car s) dc) (< dc (cdr s)))) i)
         (sub1 (length segs)))]
    [else (error 'segment-index-of "mode 必须是 'clip / 'wrap，得到 ~a" mode)]))

;; 从 (from-line,from-segment) 到 (to-line,to-segment) 的有向视觉行数。
(define (vrow-distance t width mode from-line from-segment to-line to-segment)
  (cond
    [(= from-line to-line) (- to-segment from-segment)]
    [(< from-line to-line)
     (+ (- (segment-count (track-ref t from-line) width mode) from-segment)
        (for/sum ([l (in-range (add1 from-line) to-line)])
          (segment-count (track-ref t l) width mode))
        to-segment)]
    [else (- (vrow-distance t width mode to-line to-segment from-line from-segment))]))

;; 视口每屏幕行的来源；line 越界（≥ 行数）→ 空行（render 画空白）。
(define (vrows t top-line top-segment left-column width height mode)
  (case mode
    [(clip)
     (for/vector ([r (in-range height)])
       (define li (+ top-line r))
       (vrow li left-column (+ left-column width)))]
    [(wrap)
     (let loop ([line top-line] [segs #f] [seg top-segment] [r 0] [acc '()])
       (cond
         [(>= r height) (list->vector (reverse acc))]
         [(>= line (track-length t))
          (list->vector (append (reverse acc)
                                (for/list ([x (in-range r height)]) (vrow line 0 0))))]
         [else
          (define ss (or segs (wrap-segments (track-ref t line) width)))
          (cond
            [(< seg (length ss))
             (define s (list-ref ss seg))
             (loop line ss (add1 seg) (add1 r) (cons (vrow line (car s) (cdr s)) acc))]
            [else
             (define next (add1 line))
             (if (>= next (track-length t))
                 (list->vector (append (reverse acc)
                                       (for/list ([x (in-range r height)]) (vrow next 0 0))))
                 (loop next #f 0 r acc))])]))]
    [else (error 'vrows "mode 必须是 'clip / 'wrap，得到 ~a" mode)]))

;; 上下（视觉行）移动：保持段内视觉列；目标列**向前**吸到字符起点。
(define (vrow-move t width mode p delta)
  (define line (point-line p))
  (define text (track-ref t line))
  (define dc (index->display-column text (point-column p)))
  (define segs (segments-of-line text width mode))
  (define si (segment-index-of text width mode dc))
  (define seg (list-ref segs si))
  (define vc (- dc (car seg)))
  (define target
    (cond
      [(< delta 0)
       (cond [(> si 0) (define s (list-ref segs (sub1 si))) (vrow line (car s) (cdr s))]
             [(> line 0) (define ps (segments-of-line (track-ref t (sub1 line)) width mode))
                         (define s (last ps)) (vrow (sub1 line) (car s) (cdr s))]
             [else #f])]
      [(> delta 0)
       (cond [(< si (sub1 (length segs))) (define s (list-ref segs (add1 si))) (vrow line (car s) (cdr s))]
             [(< line (sub1 (track-length t))) (define ns (segments-of-line (track-ref t (add1 line)) width mode))
                                               (define s (car ns)) (vrow (add1 line) (car s) (cdr s))]
             [else #f])]
      [else #f]))
  (cond
    [(not target) p]
    [else
     (define tl (vrow-line target)) (define ts (vrow-start-column target)) (define te (vrow-end-column target))
     (define tw (- te ts))
     (define ttext (track-ref t tl))
     (define line-width (string-display-width ttext))
     (define tdc (snap-display-column-forward ttext (+ ts (min vc tw))))
     ;; tdc == te 有两个来源：夹到段尾，或段尾宽字符右半格被吸附。都取段内最后一个字符。
     (define tcol (if (and (= tdc te) (< te line-width))
                      (display-column->index ttext (sub1 te))
                      (display-column->index ttext tdc)))
     (point tl tcol)]))
