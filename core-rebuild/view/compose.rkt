#lang racket

(require "base/screen.rkt" "../text/base/width.rkt")

;;; compose.rkt —— 多窗格合成（把若干子屏贴成一张大屏）
;;;
;;; pane        贴在合成屏上的一块子屏（row/col 可负，超出按合成宽度裁掉）
;;; composition 合成后的屏幕 + 参与合成的 pane
;;;
;;; **不透明 + 显式深度**：每个 pane 有 deep（大 = 在上）。合成按 deep 决定每一格归谁 ——
;;; 上层 pane 的整块矩形（含空白格）遮住下层；同 deep 时列表靠后者在上。
;;;
;;; overlay（光标 / 选区）：pane 自带的 overlay 全部参与合成，
;;; 「谁该画 overlay」由上游在渲染每块 pane 时就决定好了（传 selections 或 #f）。
;;; 于是 compose 只按矩形与深度合成，不依赖任何标签。

(provide
 ;; ---------- 类型 ----------
 (struct-out pane)                ; row / column / screen / deep
 (struct-out composition)         ; width / height / panes / screen

 ;; ---------- 合成 ----------
 panes->screen                    ; width height panes → screen
 panes->composition)              ; width height panes → composition

(struct pane (row column screen deep) #:transparent)
;; row/col : 屏幕坐标（可负）；deep : 深度（大 = 上）
(struct composition (width height panes screen) #:transparent)

;;; ---------- 全量合成 ----------

(define (panes->screen width height panes)
  ;; 单 pane：无遮挡，直接走 run 路径（省掉 cell 往返）。
  ;; 多 pane：建 owner 网格，按格遮挡。
  (define single? (and (pair? panes) (null? (cdr panes))))
  (define owner (if single? #f (and (pair? panes) (build-owner width height panes))))
  (define by-row (if single? #f (build-panes-by-row height panes)))
  (define-values (cursors regions) (compose-overlay width height panes owner))
  (screen width height
          (for/vector ([r (in-range height)])
            (cond
              [(null? panes) '()]
              [single? (compose-row-single width (car panes) r)]
              [else (compose-row width (vector-ref by-row r) (vector-ref owner r) r)]))
          cursors regions))

;; 按行索引 pane：pane -> 它覆盖的每一行都挂上。避免 compose-row 每行扫全部 pane。
(define (build-panes-by-row height panes)
  (define v (make-vector height '()))
  (for ([p (in-list panes)])
    (define pr (pane-row p))
    (define sh (screen-height (pane-screen p)))
    (for ([r (in-range (max 0 pr) (min height (+ pr sh)))])
      (vector-set! v r (cons p (vector-ref v r)))))
  v)

;; 单 pane 合成一行：run 平移 + 裁剪，无遮挡判定。
(define (compose-row-single width p row)
  (define lr (- row (pane-row p)))
  (if (and (>= lr 0) (< lr (screen-height (pane-screen p))))
      (filter values
              (for/list ([rn (in-list (screen-row (pane-screen p) lr))])
                (clip-run (shift-run rn (pane-column p)) width)))
      '()))

(define (shift-run rn x) (struct-copy run rn [column (+ x (run-column rn))]))

;; 把 run 水平裁剪到 [0, limit)；整字丢弃（宽字符跨边界不切半）。
(define (clip-run rn limit)
  (define c0 (run-column rn))
  (define s (run-text rn))
  (define out (open-output-string))
  (define col c0)
  (define new-column #f)
  (for ([ch (in-string s)])
    (define cw (char-display-width ch))
    (when (and (> cw 0) (>= col 0) (<= (+ col cw) limit))
      (unless new-column (set! new-column col))
      (write-char ch out))
    (set! col (+ col cw)))
  (define text* (get-output-string out))
  (if (zero? (string-length text*)) #f (run new-column text* (run-face rn))))

;; owner[r][c]：覆盖该格的最高 pane（deep 大者；同 deep 列表靠后者）。#f = 无。
;; 只认 pane 的**矩形**，不看其内容 —— 所以空白格也算被上层遮挡。
(define (build-owner width height panes)
  (define ordered (sort panes < #:key pane-deep))    ; 稳定：低 → 高，后者覆盖
  (for/vector ([r (in-range height)])
    (define rowv (make-vector width #f))
    (for ([p (in-list ordered)])
      (pane-columns p width r (lambda (c) (vector-set! rowv c p))))
    rowv))

;; 对 pane 覆盖第 r 行的每个屏幕列 c（裁到 [0,width)）调 f。
(define (pane-columns p width r f)
  (define lr (- r (pane-row p)))
  (when (and (>= lr 0) (< lr (screen-height (pane-screen p))))
    (define base (pane-column p))
    (for ([c (in-range (max 0 base)
                       (min width (+ base (screen-width (pane-screen p)))))])
      (f c))))

;; 合成一行：只为该格 owner 的 pane 画它的字符（下层在同一格的内容被上层遮挡）。
;; panes 已经是「覆盖本行」的 pane（build-panes-by-row 的结果）。
(define (compose-row width panes owner-row row)
  (define cells (make-vector width #f))
  (for ([p (in-list panes)])
    (define lr (- row (pane-row p)))
    (when (and (>= lr 0) (< lr (screen-height (pane-screen p))))
      (define base (pane-column p))
      (for ([rn (in-list (screen-row (pane-screen p) lr))])
        (define col (+ base (run-column rn)))
        (for ([ch (in-string (run-text rn))])
          (define cw (char-display-width ch))
          ;; 整字完整落在屏内，且两格归属都是 p，才画（宽字符不切半 / 不越界）。
          (when (and (> cw 0) (>= col 0) (<= (+ col cw) width)
                     (eq? (vector-ref owner-row col) p)
                     (or (= cw 1) (eq? (vector-ref owner-row (add1 col)) p)))
            (vector-set! cells col (cons ch (run-face rn)))
            (when (= cw 2) (vector-set! cells (add1 col) 'tail)))
          (set! col (+ col cw))))))
  (cells->runs cells))

;; 显示格向量 → runs：相邻同 face 的字符合一；#f / 'tail 断开。
(define (cells->runs cells)
  (define n (vector-length cells))
  (define out '())
  (define start #f) (define face #f) (define end 0) (define chars '())
  (define (flush!)
    (when start
      (set! out (cons (run start (list->string (reverse chars)) face) out))
      (set! start #f) (set! face #f) (set! chars '())))
  (for ([i (in-range n)])
    (define cell (vector-ref cells i))
    (cond
      [(or (not cell) (eq? cell 'tail)) (flush!)]
      [else
       (define ch (car cell)) (define f (cdr cell))
       (cond
         [(and start (equal? f face) (= i end))
          (set! chars (cons ch chars))
          (set! end (+ i (char-display-width ch)))]
         [else
          (flush!)
          (set! start i) (set! face f) (set! chars (list ch))
          (set! end (+ i (char-display-width ch)))])]))
  (flush!)
  (reverse out))

;;; ---------- overlay ----------

;; 所有 pane 自带的 overlay 全部参与合成；再按 owner 遮掉被上层覆盖的格（owner=#f 时无遮挡）。
(define (compose-overlay width height panes owner)
  (values
   (append*
    (for/list ([p (in-list panes)])
      (filter values
              (for/list ([c (in-list (screen-cursors (pane-screen p)))])
                (define r (+ (pane-row p) (cursor-row c)))
                (define col (+ (pane-column p) (cursor-column c)))
                (and (>= r 0) (< r height) (>= col 0) (< col width)
                     (or (not owner) (eq? (vector-ref (vector-ref owner r) col) p))
                     (cursor r col (cursor-primary? c)))))))
   (append*
    (for/list ([p (in-list panes)])
      (append*
       (for/list ([g (in-list (screen-regions (pane-screen p)))])
         (define r (+ (pane-row p) (region-row g)))
         (if (or (< r 0) (>= r height))
             '()
             (visible-regions width owner p r
                              (+ (pane-column p) (region-start-column g))
                              (+ (pane-column p) (region-end-column g))
                              (region-primary? g)))))))))

;; 一条 region 在 [b0,b1) 上对 owner 可见的子段 → region 列表（owner=#f = 整段可见）。
(define (visible-regions width owner p r b0 b1 primary?)
  (if (not owner)
      (let ([c0 (max 0 b0)] [c1 (min width b1)])
        (if (>= c0 c1) '() (list (region r c0 c1 primary?))))
      (for/list ([span (in-list (owned-spans (vector-ref owner r) p
                                              (max 0 b0) (min width b1)))])
        (region r (car span) (cdr span) primary?))))

;; owner-row 里属于 p 的连续列区间（半开 [a,b)）→ (listof (cons a b))。
(define (owned-spans owner-row p c0 c1)
  (define out '())
  (let loop ([c c0])
    (cond
      [(>= c c1) (reverse out)]
      [(eq? (vector-ref owner-row c) p)
       (let inner ([e c])
         (cond
           [(and (< e c1) (eq? (vector-ref owner-row e) p)) (inner (add1 e))]
           [else (set! out (cons (cons c e) out)) (loop e)]))]
      [else (loop (add1 c))]))
  out)

;; 全量合成 → composition（含屏幕）。
(define (panes->composition width height panes)
  (composition width height panes (panes->screen width height panes)))
