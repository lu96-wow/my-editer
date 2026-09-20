#lang racket

(require "../atom/point.rkt" "../doc/buffer.rkt" "../unit/properties.rkt"
         "../atom/restrict.rkt" rackunit)

;;; viewport/render.rkt —— 单行渲染：buffer 一行 → glyph 向量
;;;
;;; 只做**语义合成**：把一行的 properties（表现层 runs）逐段算出 face，
;;; 产出 (ch . face) 的 glyph 向量。
;;; 布局（折行/裁剪）、屏幕帧、滚动都在 viewport 层，与本层无关。

(provide
 (struct-out glyph)
 (struct-out rendered-line)
 render-line)

(struct glyph (ch face) #:transparent)
;; face : hash（语义 face）

(struct rendered-line (glyphs) #:transparent)
;; glyphs : (vectorof glyph)

(define empty-plist (hash))

;; runs 按 start 升序的 (start end payload)。返回覆盖列 a 的 payload（#f 未覆盖），
;; 以及其后第一个 end > a 的剩余 runs。让每段只需向前走，整体 O(P+O)。
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
  (define points
    (sort (remove-duplicates
           (append (list 0 n)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) p-runs)))
          <))
  (define glyphs (make-vector n #f))
  (let loop ([pts (drop-right points 1)] [bnd (rest points)] [pi p-runs])
    (cond
      [(null? pts) (void)]
      [else
       (define a (car pts)) (define z (car bnd))
       (define-values (plist pi*) (run-cover-at pi a))
       (define face (or plist empty-plist))
       (for ([j (in-range a z)]) (vector-set! glyphs j (glyph (string-ref text j) face)))
       (loop (cdr pts) (cdr bnd) pi*)]))
  (rendered-line glyphs))

;;; ---------- 测试 ----------

(module+ test
  (define (rline->string b i)
    (list->string (for/list ([g (in-vector (rendered-line-glyphs (render-line b i)))])
                    (glyph-ch g))))
  (define (face-at b i j)
    (glyph-face (vector-ref (rendered-line-glyphs (render-line b i)) j)))

  (define b0 (buffer-open "hello\nworld"))
  (check-equal? (rline->string b0 0) "hello")
  (check-equal? (face-at b0 0 0) (hash))

  ;; 属性 → face
  (define b1 (buffer-put-property b0 (point 0 1) (point 0 4) 'face 'bold))
  (check-equal? (face-at b1 0 0) (hash))
  (check-equal? (face-at b1 0 1) (hash 'face 'bold))
  (check-equal? (face-at b1 0 3) (hash 'face 'bold))
  (check-equal? (face-at b1 0 4) (hash))

  ;; 约束不进 face
  (define b2 (buffer-put-restrict b1 (point 0 1) (point 0 4) (restrict #t)))
  (check-equal? (face-at b2 0 2) (hash 'face 'bold))

  (displayln "render.rkt: all tests passed"))
