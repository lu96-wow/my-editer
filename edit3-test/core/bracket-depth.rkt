#lang racket

;;; edit3-test/bracket-depth.rkt —— 括号嵌套深度背景（纯）

(require rackunit racket/list
         "../../edit3/core/face.rkt"
         "../../edit3/core/bracket-depth.rkt")

(define rkt (build-path "/tmp" "x.rkt"))
(define txt (build-path "/tmp" "x.txt"))

;; 每格 face → level（#f 保留）。
(define (levels path text)
  (for/list ([vec (in-list (bracket-depth-lines path text))])
    (for/list ([f (in-vector vec)])
      (cond [(not f) #f]
            [(palette-bg? f) (palette-bg-index f)]
            [else 'other]))))

;; 基本嵌套：最外层 0，内层 1
(check-equal? (levels rkt "(a (b) c)")
              '((0 0 0 1 1 1 0 0 0)))

;; 多层：((x)) → 内容属于最内层括号对（其 level=1）
(check-equal? (levels rkt "((x))")
              '((0 1 1 1 0)))

;; 不在任何括号里 → 全 #f
(check-equal? (levels rkt "hello")
              '((#f #f #f #f #f)))

;; 字符串里的括号不上深度色（也不会推动栈）
(check-equal? (levels rkt "(\"(\")")
              '((0 0 0 0 0)))

;; 行注释里的 ')' 不闭合；下一行仍在层 1
(check-equal? (levels rkt "(a (b ; )\n c)")
              '((0 0 0 1 1 1 1 1 1) (1 1 1)))

;; 字符字面量 #\( 不当括号
(check-equal? (levels rkt "(#\\()")
              '((0 0 0 0 0)))

;; 非 Racket 文件不做词法跳过：字符串里的括号照算
(check-equal? (levels txt "(\"(\")")
              '((0 0 1 1 1)))

(displayln "edit3/bracket-depth.rkt: all tests passed")
