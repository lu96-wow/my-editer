#lang racket

;; 由 core/text/base/track.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/text/base/track.rkt")

(define (mk lst [m 4]) (track-of-list lst m))
(define (ls t) (track->list t))

(define t0 (mk '("a" "b" "c" "d" "e")))
(check-equal? (ls t0) '("a" "b" "c" "d" "e"))
(check-equal? (track-length t0) 5)
(check-equal? (track-ref t0 4) "e")
(check-eq? (track-check t0) t0)
(check-equal? (ls (track-empty)) '())
(check-exn exn:fail? (lambda () (track-ref t0 5)))

(check-equal? (track-slice t0 1 4) '("b" "c" "d"))
(check-equal? (ls (track-take t0 2)) '("a" "b"))
(check-equal? (ls (track-drop t0 2)) '("c" "d" "e"))
(check-equal? (ls (track-append (track-take t0 2) (track-drop t0 2))) (ls t0))

(check-equal? (ls (track-splice t0 2 2 '("x" "y"))) '("a" "b" "x" "y" "c" "d" "e"))
(check-equal? (ls (track-splice t0 1 3 '())) '("a" "d" "e"))
(check-equal? (ls (track-splice t0 1 3 '("x"))) '("a" "x" "d" "e"))
(check-eq? (track-splice t0 2 2 '()) t0)
(check-equal? (ls (track-delete t0 0 5)) '())

(check-equal? (ls (track-map t0 string-upcase)) '("A" "B" "C" "D" "E"))
(check-equal? (ls (track-rewrite t0 1 string-upcase)) '("a" "B" "c" "d" "e"))

;; 行元素是 vector 时同样工作（属性轨）
(define ta (mk (list (vector 'a) (vector 'b) (vector 'c))))
(check-equal? (track-ref ta 1) (vector 'b))
(check-equal? (ls (track-rewrite ta 1 (lambda (v) (vector-append v (vector 'x)))))
              (list (vector 'a) (vector 'b 'x) (vector 'c)))

;; 创建参数
(check-equal? (track-max (track-of-list '("a" "b" "c") 2)) 2)
(check-equal? (track-max (track-of-list '("a"))) default-chunk-lines)

;; append 两轨 max 不同：结果 max = 较大者，且块不越界（t-check 会查 ≤max）
(define tA (track-of-list '("a" "b" "c") 2))              ; max 2
(define tB (track-of-list '("d" "e" "f" "g" "h") 8))    ; max 8，一块 5 行（> 2）
(define tAB (track-append tA tB))
(check-equal? (track-max tAB) 8)
(check-equal? (ls tAB) '("a" "b" "c" "d" "e" "f" "g" "h"))
(check-eq? (track-check tAB) tAB)
(define tBA (track-append tB tA))
(check-equal? (track-max tBA) 8)
(check-equal? (ls tBA) '("d" "e" "f" "g" "h" "a" "b" "c"))
(check-eq? (track-check tBA) tBA)

;; 差分随机测试（与列表模型比对）
(define model (for/list ([i (in-range 30)]) (number->string i)))
(define tt (mk model))
(parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
  (random-seed 3)
  (for ([_ (in-range 500)])
    (define n (length model))
    (define s (random (add1 n)))
    (define e (+ s (random (add1 (- n s)))))
    (define k (random 4))
    (define news (for/list ([i (in-range k)]) (format "n~a" (random 100))))
    (set! model (append (take model s) news (drop model e)))
    (set! tt (track-splice tt s e news))
    (check-equal? (ls tt) model)
    (track-check tt))
  (check-equal? (ls tt) model))

(displayln "track.rkt: all tests passed")
