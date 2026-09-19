#lang racket

(require "../text/point.rkt" "../text/buffer.rkt" "../text/properties.rkt"
         "../text/overlay.rkt" rackunit)

;;; render.rkt —— 行渲染：buffer 一行 → glyph 向量
;;;
;;; 只做「语义合成」：合并一行上 properties-runs 与 overlay-runs 的边界，
;;; 逐段合成 face，产出 (ch, face) 的 glyph 向量。
;;; 布局（折行/裁剪）、屏幕帧缓冲、滚动都在 view / project 层，与本层无关。

(provide
 (struct-out glyph)
 (struct-out rendered-line)
 render-line)

(struct glyph (ch face) #:transparent)
;; face : immutable hash（语义 face）

(struct rendered-line (glyphs) #:transparent)
;; glyphs : (vectorof glyph)

(define empty-plist (hash))

;;; ---------- face 合成 ----------

(define (hash-merge-into base extras)
  (for/fold ([h base]) ([(k v) (in-hash extras)])
    (hash-set h k v)))

;; 给定位置的 presentation plist 和 overlay 列表（按 priority 降序）。
;; 两者都是**纯表现层**（行为属性已是 struct 字段，不在 plist 里），所以无需任何过滤。
;; presentation 视作 priority 0 且在同优先级中最后合并：
;;   priority <= 0 的 overlay 在 presentation 之下，priority > 0 的在之上。
(define (compute-face p-plist ovs)
  (define-values (below above)
    (partition (lambda (ov) (<= (overlay-priority ov) 0)) ovs))
  (define f0 (for/fold ([f (hash)]) ([ov (in-list (reverse below))])
               (hash-merge-into f (overlay-presentation ov))))
  (define f1 (hash-merge-into f0 p-plist))
  (for/fold ([f f1]) ([ov (in-list (reverse above))])
    (hash-merge-into f (overlay-presentation ov))))

;;; ---------- 单行渲染 ----------

;; 给定「按 start 升序」的 runs（每项 = (start end payload)）和一个单调递增的列 a，
;; 返回 (values 覆盖 a 的 payload(#f 未覆盖) 及其后第一个 end > a 的 run 列表)。
;; 避免 render-line 每段都全表扫描（O((P+O)²) → O(P+O)）。
(define (run-cover-at runs a)
  (let skip ([r runs])
    (cond
      [(null? r) (values #f r)]
      [(<= (cadr (car r)) a) (skip (cdr r))]
      [(<= (car (car r)) a) (values (caddr (car r)) r)]
      [else (values #f r)])))

(define (render-line b i)
  (define text (buffer-line-ref b i))
  (define n (string-length text))
  (define p-runs (properties-runs (buffer-properties b) i n))
  (define o-runs (overlay-table-runs (buffer-overlays b)
                                     (buffer-markers b)
                                     i n))
  (define all-points
    (sort (remove-duplicates
           (append (list 0 n)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) p-runs)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) o-runs)))
          <))
  (define glyphs (make-vector n #f))
  (let loop ([pts (drop-right all-points 1)]
             [bnd (rest all-points)]
             [pi p-runs]
             [oi o-runs])
    (cond
      [(null? pts) (void)]
      [else
       (define a (car pts))
       (define b (car bnd))
       (define-values (p-plist pi*) (run-cover-at pi a))
       (define-values (ovs oi*)     (run-cover-at oi a))
       (define face (compute-face (or p-plist empty-plist) (or ovs '())))
       (for ([j (in-range a b)])
         (vector-set! glyphs j (glyph (string-ref text j) face)))
       (loop (cdr pts) (cdr bnd) pi* oi*)]))
  (rendered-line glyphs))

(module+ test
  (define (rline->string b i)
    (list->string (for/list ([g (in-vector (rendered-line-glyphs (render-line b i)))])
                    (glyph-ch g))))

  (define b0 (buffer-open "hello\nworld"))
  (check-equal? (rline->string b0 0) "hello")
  (check-equal? (rline->string b0 1) "world")

  ;; 属性
  (define b1 (buffer-put-property b0 0 1 4 'face 'bold))
  (define g1 (rendered-line-glyphs (render-line b1 0)))
  (check-equal? (glyph-face (vector-ref g1 0)) (hash))
  (check-equal? (glyph-face (vector-ref g1 1)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref g1 3)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref g1 4)) (hash))

  ;; overlay + priority（priority>0 覆盖 props；priority=0 在 props 之下）
  (define-values (b2 oid2) (buffer-add-overlay b0 (point 0 1) (point 0 4)
                                              (hash 'face 'region)))
  (define g2 (rendered-line-glyphs (render-line b2 0)))
  (check-equal? (glyph-face (vector-ref g2 1)) (hash 'face 'region))
  (define b3 (buffer-put-property b2 0 1 4 'face 'bold))
  (define-values (b4 oid4) (buffer-add-overlay b3 (point 0 2) (point 0 3)
                                              (hash 'face 'highlight) #:priority 5))
  (define g4 (rendered-line-glyphs (render-line b4 0)))
  (check-equal? (glyph-face (vector-ref g4 1)) (hash 'face 'bold))        ; p0 overlay < props
  (check-equal? (glyph-face (vector-ref g4 2)) (hash 'face 'highlight))   ; p5 > 一切
  (check-equal? (glyph-face (vector-ref g4 3)) (hash 'face 'bold))

  ;; 约束不进 face：read-only 走 restrict 槽，face 里只有表现层
  (define b5 (buffer-put-property b0 0 1 4 'face 'bold))
  (define b5b (buffer-put-restrict b5 0 1 4 (restrict #t)))
  (define g5 (rendered-line-glyphs (render-line b5b 0)))
  (check-equal? (glyph-face (vector-ref g5 2)) (hash 'face 'bold))

  (displayln "render.rkt: all tests passed"))
