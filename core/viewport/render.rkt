#lang racket

(require "../atom/point.rkt" "../doc/buffer.rkt" rackunit)

;;; viewport/render.rkt —— 单行渲染：buffer 一行 → glyph 向量
;;;
;;; face **全部来自投影参数 face-provider**（派生 face = content 的纯函数，如语法高亮）；
;;; 文档里不存 face。provider : buffer line -> (listof (list start end face))。
;;; 布局（折行/裁剪）、屏幕帧、滚动都在 viewport 层，与本层无关。

(provide
 (struct-out glyph)
 (struct-out rendered-line)
 empty-face-provider
 render-line)

(struct glyph (ch face) #:transparent)
;; face : any/c（语义值；结构由应用定义，常用 (hash 'face 'keyword)）

(struct rendered-line (glyphs) #:transparent)
;; glyphs : (vectorof glyph)

;; 缺省 provider：无派生 face。
(define (empty-face-provider _b _line) '())

;; runs 按 start 升序的 (start end payload)。返回覆盖列 a 的 payload（#f 未覆盖），
;; 以及其后第一个 end > a 的剩余 runs。让每段只需向前走，整体 O(D)。
(define (run-cover-at runs a)
  (let skip ([r runs])
    (cond
      [(null? r) (values #f r)]
      [(<= (cadr (car r)) a) (skip (cdr r))]
      [(<= (car (car r)) a) (values (caddr (car r)) r)]
      [else (values #f r)])))

(define (render-line b i [face-provider empty-face-provider])
  (define text (buffer-line-ref b i))
  (define n (string-length text))
  (define d-runs (face-provider b i))
  (define points
    (sort (remove-duplicates
           (append (list 0 n)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) d-runs)))
          <))
  (define glyphs (make-vector n #f))
  (let loop ([pts (drop-right points 1)] [bnd (rest points)] [di d-runs])
    (cond
      [(null? pts) (void)]
      [else
       (define a (car pts)) (define z (car bnd))
       (define-values (dface di*) (run-cover-at di a))
       (define face (or dface (hash)))          ; 无 face 段 → 默认空 face 值 (hash)
       (for ([j (in-range a z)]) (vector-set! glyphs j (glyph (string-ref text j) face)))
       (loop (cdr pts) (cdr bnd) di*)]))
  (rendered-line glyphs))

;;; ---------- 测试 ----------

(module+ test
  (define (face-at b i j [provider empty-face-provider])
    (glyph-face (vector-ref (rendered-line-glyphs (render-line b i provider)) j)))

  (define b0 (buffer-open "hello\nworld"))
  ;; 无 provider → 无 face；provider 在投影时给出派生 face
  (check-equal? (face-at b0 0 0) (hash))                    ; 无 provider → 无 face

  ;; 派生 face：投影时给出，不进文档
  (define (provider _b line)
    (if (zero? line) (list (list 0 5 (hash 'face 'keyword))) '()))
  (check-equal? (face-at b0 0 0 provider) (hash 'face 'keyword))
  (check-equal? (face-at b0 1 0 provider) (hash))           ; 第 1 行无匹配

  ;; 多段
  (define (provider2 _b _line)
    (list (list 0 2 (hash 'face 'a)) (list 3 5 (hash 'face 'b))))
  (check-equal? (face-at b0 0 0 provider2) (hash 'face 'a))
  (check-equal? (face-at b0 0 2 provider2) (hash))
  (check-equal? (face-at b0 0 3 provider2) (hash 'face 'b))

  (displayln "render.rkt: all tests passed"))
