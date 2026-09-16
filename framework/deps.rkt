#lang racket

;;; deps.rkt —— 依赖分层（供 plugin-dag / edit-plugins 共用）
;;;
;;; 输入 specs + 两个投影（name / deps），按「最长依赖深度」分层：
;;;   - 无依赖的节点在第 0 层，可并行
;;;   - 依赖别的节点的，层号 = 被依赖节点的最大层号 + 1
;;;   - 依赖环 → 报错
;;; 本模块只做纯分层，不知道线程/插件，也不知道 spec 的具体类型。

(provide compute-levels)

(define (compute-levels specs name deps)
  (define depmap (for/hash ([s specs]) (values (name s) (deps s))))
  (define memo (make-hash))
  (define visiting (make-hash))          ; 环检测
  (define (level nm)
    (when (hash-ref visiting nm #f)
      (error 'compute-levels "依赖环: ~a" nm))
    (cond
      [(hash-ref memo nm #f) => identity]
      [else
       (hash-set! visiting nm #t)
       (define l
         (if (null? (hash-ref depmap nm '()))
             0
             (add1 (apply max (map level (hash-ref depmap nm '()))))))
       (hash-remove! visiting nm)
       (hash-set! memo nm l)
       l]))
  (define lvls (for/hash ([s specs]) (values (name s) (level (name s)))))
  (define maxlvl (apply max 0 (hash-values lvls)))
  (for/list ([l (in-range (add1 maxlvl))])
    (for/list ([s specs] #:when (= l (hash-ref lvls (name s)))) s)))
