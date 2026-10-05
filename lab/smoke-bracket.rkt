#lang racket

;;; lab/smoke-bracket.rkt —— 括号增量扫描的等价性回归
;;;
;;; 随机生成文本 + 随机编辑，验证 bracket-change（增量）与全量扫描结果一致。
;;; 用固定随机种子，可复现。

(require racket/list
         rackunit
         "../core/text/base/line.rkt"
         "base/face.rkt"
         "base/brackets.rkt"
         "plugin/shadow.rkt")

(define alphabet (list #\( #\) #\[ #\] #\{ #\} #\a #\b #\space #\newline #\newline))
(define (rnd-char) (list-ref alphabet (random (length alphabet))))
(define (rnd-text n) (list->string (for/list ([_ (in-range n)]) (rnd-char))))

(define (norm fills)
  (sort (map (lambda (f) (list (car f) (cadr f) (caddr f) (cadddr f)
                               (palette-color-index (list-ref f 4))))
             fills)
        (lambda (a b)
          (or (< (car a) (car b))
              (and (= (car a) (car b)) (< (cadr a) (cadr b)))
              (and (= (car a) (car b)) (= (cadr a) (cadr b)) (< (caddr a) (caddr b)))
              (and (= (car a) (car b)) (= (cadr a) (cadr b)) (= (caddr a) (caddr b))
                   (< (cadddr a) (cadddr b)))))))

(define (random-edit text)
  (define lines (string->lines text))
  (define n (length lines))
  (define l0 (random n))
  (define c0 (random (add1 (string-length (list-ref lines l0)))))
  (define l1 (min (sub1 n) (+ l0 (random 2))))
  (define c1 (if (= l1 l0)
                 (min (string-length (list-ref lines l0)) (+ c0 (random 3)))
                 (random (add1 (string-length (list-ref lines l1))))))
  (list l0 c0 l1 (max c1 (if (= l1 l0) c0 0)) (rnd-text (random 4))))

(random-seed 20261005)
(define failures (box 0))
(for ([_ (in-range 2000)])
  (define t0 (rnd-text (+ 3 (random 30))))
  (define e (random-edit t0))
  (define t1 (shadow-text (shadow-apply (shadow-open t0) (list e))))
  (define-values (st0 _fl) (bracket-open t0 #f))
  (define-values (_st1 inc) (bracket-change st0 e (list->vector (string->lines t1)) #f))
  (unless (equal? (norm inc) (norm (bracket-fills t1)))
    (set-box! failures (add1 (unbox failures)))))
(check-equal? (unbox failures) 0)

(displayln "lab smoke-bracket: ok")
