#lang racket

(require racket/string
         "face.rkt")

;;; lab/base/brackets.rkt —— 括号配对 + 嵌套深度（纯，输入整篇文本）
;;;
;;; 输出 core 的高亮填充 runs： (list l0 c0 l1 c1 face)。
;;; **整对区间（含两端括号）** 都按该对深度上背景色，不只是括号本身；
;;; 嵌套时内层后填、覆盖外层，于是每个字符取“最内层包围它的括号”的深度。
;;; face = (bracket-depth n)，颜色由主题决定（见 theme/）。
;;;
;;; 不做语法分析：字符串 / 注释里的括号也照算。未配对的括号不产生区间。
;;; 纯函数：可放到后台进程 / place 里跑（见 plugin/）。

(provide bracket-fills)

(define open->close (hash #\( #\) #\[ #\] #\{ #\}))

(define (bracket-fills text)
  (define lines (string-split text "\n"))
  (define stack '())                       ; (list (list line col open-ch depth))
  (define fills '())                       ; 内层先闭合 → 先 cons 内层、后 cons 外层
  (for ([line (in-list lines)] [ln (in-naturals)])
    (for ([ch (in-string line)] [col (in-naturals)])
      (cond
        [(hash-has-key? open->close ch)
         (set! stack (cons (list ln col ch (length stack)) stack))]
        [(memv ch '(#\) #\] #\}))
         (match stack
           [(cons (list ol oc och odepth) rest)
            #:when (eqv? (hash-ref open->close och) ch)
            (set! stack rest)
            ;; 整对区间闭区间：开括号 → 闭括号（含），按该对深度上色。
            ;; cons 使外层排在前面 → 批量填充时外层先写、内层后写覆盖。
            (set! fills (cons (list ol oc ln (add1 col) (bracket-depth odepth)) fills))]
           [_ (void)])])))
  fills)
