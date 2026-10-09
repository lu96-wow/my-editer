#lang racket

;;; edit/test/bracket-pair-test.rkt —— 括号配对/深度：增量 vs 全量（headless）
;;;
;;;   raco test edit/test/bracket-pair-test.rkt

(require rackunit
         "../plugin/builtin/bracket-pair.rkt")

(define (pairs-of text) (define-values (_st pairs) (bracket-open text "x.rkt")) pairs)

;; 嵌套：外层 level 0、内层 level 1
(define ps (pairs-of "(a\n [b]\n c)\n"))
(check-not-false (member (list 0 0 2 3 0) ps))    ; ( … ) level 0
(check-not-false (member (list 1 1 1 4 1) ps))    ; [ … ] level 1

;; 增量（行内插入，改变嵌套）：结果应与全量一致
(define-values (st1 _) (bracket-open "(x)\n" "x.rkt"))
;; 在 (0,1) 插入 "[y]"（编辑后坐标 after range (0,1)-(0,4)）
(define new-lines (vector "([y]x)" ""))
(define-values (st2 inc-pairs)
  (bracket-change st1 (list (list 0 1 0 4)) new-lines "x.rkt"))
(define full-pairs (pairs-of "([y]x)\n"))
(check-equal? (length inc-pairs) (length full-pairs))
(for ([p (in-list full-pairs)]) (check-not-false (member p inc-pairs)))

;; 增量（删除使嵌套变浅）：同样应与全量一致
(define-values (st3 _p3) (bracket-open "([y]x)\n" "x.rkt"))
(define del-lines (vector "(x)" ""))
(define-values (st4 inc-pairs2)
  (bracket-change st3 (list (list 0 1 0 4)) del-lines "x.rkt"))   ; 删 [y]
(define full-pairs2 (pairs-of "(x)\n"))
(check-equal? (length inc-pairs2) (length full-pairs2))
(for ([p (in-list full-pairs2)]) (check-not-false (member p inc-pairs2)))
