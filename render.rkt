#lang racket

(require "cursor.rkt" "buffer.rkt" "properties.rkt" "overlay.rkt" rackunit)

;;; render.rkt —— 行渲染：buffer 一行 → glyph 向量
;;;
;;; 只做「语义合成」：合并一行上 props-runs 与 overlay-runs 的边界，
;;; 逐段合成 face，产出 (ch, face) 的 glyph 向量。
;;; 布局（折行/裁剪）、屏幕帧缓冲、滚动都在 view / paint 层，与本层无关。

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

;; overlay 的控制键：进入 plist 但不属于 face
(define overlay-control-keys '(priority evaporate))

(define (face-plist p)
  (for/hash ([(k v) (in-hash p)] #:unless (memq k overlay-control-keys))
    (values k v)))

;; 给定位置的 props plist 和 overlay 列表（按 priority 降序）。
;; props 视作 priority 0 且在同优先级中最后合并：
;;   priority <= 0 的 overlay 在 props 之下，priority > 0 的在 props 之上。
(define (compute-face p-plist ovs)
  (define-values (below above)
    (partition (lambda (ov) (<= (overlay-priority ov) 0)) ovs))
  (define f0 (for/fold ([f (hash)]) ([ov (in-list (reverse below))])
               (hash-merge-into f (face-plist (overlay-plist ov)))))
  (define f1 (hash-merge-into f0 (face-plist p-plist)))
  (for/fold ([f f1]) ([ov (in-list (reverse above))])
    (hash-merge-into f (face-plist (overlay-plist ov)))))

;;; ---------- 单行渲染 ----------

(define (render-line b i)
  (define text (buffer-line-ref b i))
  (define n (string-length text))
  (define p-runs (props-runs (buffer-properties b) i n))
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
  (for ([a (in-list (drop-right all-points 1))]
        [b (in-list (rest all-points))])
    (define p-plist
      (or (for/first ([seg (in-list p-runs)]
                      #:when (and (<= (car seg) a) (> (cadr seg) a)))
            (caddr seg))
          empty-plist))
    (define ovs
      (or (for/first ([seg (in-list o-runs)]
                      #:when (and (<= (car seg) a) (> (cadr seg) a)))
            (caddr seg))
          '()))
    (define face (compute-face p-plist ovs))
    (for ([j (in-range a b)])
      (vector-set! glyphs j (glyph (string-ref text j) face))))
  (rendered-line glyphs))

(module+ test
  (define (rline->string b i)
    (list->string (for/list ([g (in-vector (rendered-line-glyphs (render-line b i)))])
                    (glyph-ch g))))

  (define b0 (buffer-open "hello\nworld"))
  (check-equal? (rline->string b0 0) "hello")
  (check-equal? (rline->string b0 1) "world")

  ;; 属性
  (define b1 (buffer-put-text-property b0 0 1 4 'face 'bold))
  (define g1 (rendered-line-glyphs (render-line b1 0)))
  (check-equal? (glyph-face (vector-ref g1 0)) (hash))
  (check-equal? (glyph-face (vector-ref g1 1)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref g1 3)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref g1 4)) (hash))

  ;; overlay + priority（priority>0 覆盖 props；priority=0 在 props 之下）
  (define-values (b2 oid2) (buffer-make-overlay b0 (cursor 0 1) (cursor 0 4)
                                              (hash 'face 'region)))
  (define g2 (rendered-line-glyphs (render-line b2 0)))
  (check-equal? (glyph-face (vector-ref g2 1)) (hash 'face 'region))
  (define b3 (buffer-put-text-property b2 0 1 4 'face 'bold))
  (define-values (b4 oid4) (buffer-make-overlay b3 (cursor 0 2) (cursor 0 3)
                                              (hash 'face 'highlight 'priority 5)))
  (define g4 (rendered-line-glyphs (render-line b4 0)))
  (check-equal? (glyph-face (vector-ref g4 1)) (hash 'face 'bold))        ; p0 overlay < props
  (check-equal? (glyph-face (vector-ref g4 2)) (hash 'face 'highlight))   ; p5 > 一切
  (check-equal? (glyph-face (vector-ref g4 3)) (hash 'face 'bold))

  (displayln "render.rkt: all tests passed"))
