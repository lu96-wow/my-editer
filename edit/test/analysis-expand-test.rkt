#lang racket

;;; edit/test/analysis-expand-test.rkt —— 分析工具：check-syntax 展开（headless）
;;;
;;;   raco test edit/test/analysis-expand-test.rkt
;;;
;;; 只用自己的小片段；expand 会执行编译期代码，生产上必须经 worker + 沙箱。

(require rackunit
         "../plugin/analysis/tools/span.rkt"
         "../plugin/analysis/tools/expand.rkt")

(define path (string->path "/tmp/analysis-expand-test.rkt"))
(define text "#lang racket\n(define (f x) (+ x 1))\n(f 2)\n")

;;  0..12 #lang racket + \n
;;  14..20 define | 22 f(定义) | 24 x(参数) | 28 + | 30 x(使用) | 37 f(使用)
(define r (expand-analyze path text))

(check-equal? (expand-result-path r) path)

;; 语义 token：定义点带 definition 修饰
(define sem (expand-result-sem-tokens r))
(define f-def (for/first ([t (in-list sem)] #:when (equal? (sem-token-span t) (span 22 23))) t))
(check-not-false f-def)
(check-not-false (memq 'definition (sem-token-modifiers f-def)))
(check-not-false (for/or ([t (in-list sem)]) (equal? (sem-token-span t) (span 30 31))))  ; x 使用

;; 定义：f @22
(check-not-false
 (for/first ([d (in-list (expand-result-definitions r))]
             #:when (and (symbol=? 'f (definition-name d))
                         (equal? (definition-span d) (span 22 23))))
   #t))

;; 使用：f @37、x @30
(check-not-false
 (for/first ([u (in-list (expand-result-uses r))]
             #:when (and (symbol=? 'f (occurrence-name u))
                         (equal? (occurrence-span u) (span 37 38))))
   #t))

;; 无错代码：诊断为空
(check-equal? (expand-result-diagnostics r) '())

;; 读取失败（括号不闭合）：产出 error 诊断，且不抛
(define rb (expand-analyze (string->path "/tmp/analysis-expand-bad.rkt")
                           "#lang racket\n(define x\n"))
(check-true (pair? (expand-result-diagnostics rb)))
(check-equal? (diagnostic-severity (car (expand-result-diagnostics rb))) 'error)

;; 展开失败 / 垃圾输入：也不抛
(check-true (expand-result? (expand-analyze (string->path "/tmp/x.rkt") "((( ")))
(check-true (expand-result? (expand-analyze (string->path "/tmp/x.rkt") "")))
