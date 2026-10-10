#lang racket

;;; edit-rebuild/plugins/test/bracket-pair-test.rkt —— 括号配对/深度：全量层 + 增量 ≡ 全量（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/bracket-pair-test.rkt

(require rackunit
         "../highlight/bracket-pair.rkt"
         "../../core/face/face.rkt"
         "../../../core/text/base/track.rkt"
         "../../../core/text/base/line.rkt"
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/point.rkt")

(define (text-track str) (track-of-list (string->lines str)))
(define (line-face layer i) (track-ref layer i))
(define (bg layer i col)
  (define v (line-face layer i))
  (and v (vector-ref v col)))

;;; ---------- 全量层：嵌套取最内层 ----------

(define-values (_st0 layer0) (bracket-open* (text-track "(a\n [b]\n c)\n") "../../edit-rebuild/test/x.rkt"))
(check-equal? (palette-bg-index (bg layer0 0 0)) 0)     ; "(" 外层
(check-equal? (palette-bg-index (bg layer0 0 1)) 0)     ; "a"
(check-equal? (palette-bg-index (bg layer0 1 1)) 1)     ; "[" 内层
(check-equal? (palette-bg-index (bg layer0 1 2)) 1)     ; "b"
(check-equal? (palette-bg-index (bg layer0 2 1)) 0)     ; "c"

;; 词法跳过：字符串 / 注释里的括号不算
(define-values (_st1 layer1) (bracket-open* (text-track "(\")\" ; )\n x)") "../../edit-rebuild/test/x.rkt"))
(check-equal? (palette-bg-index (bg layer1 0 0)) 0)     ; 外层 "("
(check-equal? (palette-bg-index (bg layer1 0 1)) 0)     ; 字符串内 ")"
(check-equal? (palette-bg-index (bg layer1 1 1)) 0)     ; 行尾 "x" 仍在外层里

;;; ---------- 增量 ≡ 全量 ----------

(define (full-layer str)
  (define text (text-track str))
  (define-values (st _l) (bracket-open* text "../../edit-rebuild/test/x.rkt"))
  (bracket-layer text (bstate-entries st) "../../edit-rebuild/test/x.rkt"))
(define (incremental old-str new-str change)
  (define-values (st _l) (bracket-open* (text-track old-str) "../../edit-rebuild/test/x.rkt"))
  (define-values (st2 _d) (bracket-change st (list change) (text-track new-str) "../../edit-rebuild/test/x.rkt"))
  (bracket-layer (text-track new-str) (bstate-entries st2) "../../edit-rebuild/test/x.rkt"))

(define (ins l c len) (change (range-of (point l c) (point l c))
                              (range-of (point l c) (point l (+ c len)))))
(define (del l0 c0 l1 c1) (change (range-of (point l0 c0) (point l1 c1))
                                  (range-of (point l0 c0) (point l0 c0))))

;; 行内插入，使嵌套变深
(check-equal? (track->list (incremental "(x)\n" "([y]x)\n" (ins 0 1 3)))
              (track->list (full-layer "([y]x)\n")))
;; 行内删除，使嵌套变浅
(check-equal? (track->list (incremental "([y]x)\n" "(x)\n" (del 0 1 0 4)))
              (track->list (full-layer "(x)\n")))
;; 删掉开括号（破坏配对）
(check-equal? (track->list (incremental "(a [b] c)\n" "(a b] c)\n" (del 0 3 0 4)))
              (track->list (full-layer "(a b] c)\n")))
;; 删除换行（行结构变化 → 全量路径）
(check-equal? (track->list (incremental "(a\n b)\n" "(a b)\n"
                                        (change (range-of (point 0 2) (point 1 0))
                                                (range-of (point 0 2) (point 0 2)))))
              (track->list (full-layer "(a b)\n")))
