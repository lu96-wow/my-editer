#lang racket

;;; edit4-test/render.rkt —— 渲染骨架（frame → 屏幕 piece）

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/engine.rkt"
         "../edit4/content/content.rkt"
         "../edit4/view/render.rkt")

(define (pieces->screen ps w h)
  (define grid (build-vector h (lambda (_) (make-string w #\space))))
  (for ([p (in-list ps)])
    (define r (piece-row p)) (define c (piece-column p)) (define t (piece-text p))
    (when (< r h)
      (for ([ch (in-string t)] [i (in-naturals)])
        (when (< (+ c i) w) (string-set! (vector-ref grid r) (+ c i) ch)))))
  (string-join (vector->list grid) "\n"))

;;; ---------- 单窗文本 ----------

(define SZ (cons 20 5))
(define c0 (content-blank))
(define-values (c1 did vid) (content-add-doc! c0 "hello\nworld" 18 5 "t" #f))
(define w1 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 vid)))

(define (frame-of w size)
  (define-values (_c f) (ensure-layout empty-layout-cache (world-layout w) (world-floats w) size))
  f)
(define (id->vid-of w) (lambda (id) (content-vid-of (world-content w) id)))

(define fr1 (frame-of w1 SZ))
(define-values (_s r1 s1)
  (render-frame (content-ed (world-content w1)) fr1 (id->vid-of w1) vid (car SZ) (cdr SZ) #f))
(define out1 (pieces->screen (append r1 s1) (car SZ) (cdr SZ)))
(check-true (regexp-match? #rx"hello" out1))
(check-true (regexp-match? #rx"world" out1))

;;; ---------- 两列：分隔线 │ ----------

(define c2 (content-blank))
(define-values (c2a didA vidA) (content-add-doc! c2 "AAA" 8 5 "a" #f))
(define-values (c2b didB vidB) (content-add-doc! c2a "BBB" 8 5 "b" #f))
(define lay2 (split 'h 1 (list (child (size 2 #t) (leaf 0 (cons 2 2)))
                               (child (size 2 #t) (leaf 1 (cons 2 2))))))
(define w2 (make-world #:layout lay2 #:focus 0
                       #:content (content-bind (content-bind c2b 0 vidA) 1 vidB)))
(define fr2 (frame-of w2 SZ))
(define-values (_s2 r2 s2)
  (render-frame (content-ed (world-content w2)) fr2 (id->vid-of w2) vidA (car SZ) (cdr SZ) #f))
(define out2 (pieces->screen (append r2 s2) (car SZ) (cdr SZ)))
(check-true (regexp-match? #rx"AAA" out2))
(check-true (regexp-match? #rx"BBB" out2))
(check-true (regexp-match? #rx"│" out2))          ; 缝字形

;;; ---------- 浮窗框 ----------

(define fl (list (float 'F (anchor 'screen 'right 'top 0 0) (cons 6 3))))
(define w3 (make-world #:layout lay2 #:floats fl #:focus 0
                       #:content (content-bind (content-bind c2b 0 vidA) 1 vidB)))
(define fr3 (frame-of w3 SZ))
(define-values (_s3 r3 s3)
  (render-frame (content-ed (world-content w3)) fr3 (id->vid-of w3) vidA (car SZ) (cdr SZ) #f))
(define out3 (pieces->screen (append r3 s3) (car SZ) (cdr SZ)))
(check-true (regexp-match? #rx"┌" out3))
(check-true (regexp-match? #rx"└" out3))

(displayln "edit4/render.rkt: all tests passed")
