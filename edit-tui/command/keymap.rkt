#lang racket

;;; command/keymap.rkt —— 键表（纯）：键序列 → 过程
;;;
;;; 键表是一棵 trie：
;;;     叶子   过程     命中即执行
;;;     子树   keymap   前缀，继续读键
;;;
;;; 组合 `keymap-merge`：按顺序折叠，**后加入的表覆盖前面的**——
;;;   · 同一路径（同序列）→ 后面的叶子替换前面的；
;;;   · 一个键下两边都是子树 → 递归合并（各自不冲突的续键都保留）；
;;;   · 一边叶子一边子树 → 后面的整体替换前面的（前缀也是「同键」）。
;;;
;;; 构造 DSL `keys`：每条绑定写成一对方括号，最后一格是过程，前面是要按的键。
;;;
;;;     (keys [(key 'left)                 (λ () …)]
;;;           [(key 'p 'ctrl) (key 'x)     (λ () …)])
;;;
;;; 宿主读到一个事件后调 `keymap-step` 推进；`empty-keymap` 是空表。

(provide (struct-out keymap)
         empty-keymap
         keymap-set keymap-ref keymap-lookup keymap-step
         keymap-merge
         keys)

(require "key.rkt")

(struct keymap (bindings) #:transparent)
;; bindings : (hash/c key? (or/c keymap? procedure?))

(define empty-keymap (keymap (hash)))

;; 插入一条 seq → proc。路径上的旧叶子 / 旧子树按「后插覆盖」处理。
(define (keymap-set km seq proc)
  (unless (and (pair? seq) (andmap key? seq))
    (error 'keymap-set "键序列要是非空 key 列表，得到 ~a" seq))
  (unless (procedure? proc)
    (error 'keymap-set "叶子要是一个过程，得到 ~a" proc))
  (define (go h seq)
    (define k (car seq))
    (if (null? (cdr seq))
        (hash-set h k proc)
        (let* ([sub (hash-ref h k #f)]
               [sub* (if (keymap? sub) sub empty-keymap)])
          (hash-set h k (keymap (go (keymap-bindings sub*) (cdr seq)))))))
  (keymap (go (keymap-bindings km) seq)))

;; 精确查一条完整序列 → 过程 | #f（序列前缀对但没到底 → #f）
(define (keymap-ref km seq)
  (let loop ([cur km] [seq seq])
    (cond [(null? seq) (and (procedure? cur) cur)]
          [(not (keymap? cur)) #f]
          [else (loop (keymap-lookup cur (car seq)) (cdr seq))])))

;; 单步查一个键 → 子树 | 过程 | #f
(define (keymap-lookup km k)
  (and km (hash-ref (keymap-bindings km) k #f)))

;; 单步推进：'unbound（没这个键）/ 'prefix（进入子树）/ 'command（叶子）
(define (keymap-step km k)
  (define e (keymap-lookup km k))
  (cond [(not e) (values 'unbound #f)]
        [(keymap? e) (values 'prefix e)]
        [else (values 'command e)]))

;; 合并：后面的覆盖前面的。
(define (keymap-merge kms)
  (define (merge2 a b)
    (keymap
     (for/fold ([h (keymap-bindings a)]) ([(k eb) (in-hash (keymap-bindings b))])
       (define ea (hash-ref h k #f))
       (hash-set h k
                 (if (and (keymap? ea) (keymap? eb))
                     (merge2 ea eb)
                     eb)))))
  (for/fold ([acc empty-keymap]) ([km (in-list kms)]) (merge2 acc km)))

;; keys DSL：[(key …) … proc] —— 最后一格是过程，其余是键序列。
(define-syntax keys
  (syntax-rules ()
    [(_ [seq ... proc] ...)
     (keymap-from-bindings (list (list (list seq ...) proc) ...))]))

(define (keymap-from-bindings binds)
  (for/fold ([km empty-keymap]) ([b (in-list binds)])
    (keymap-set km (car b) (cadr b))))

(module+ test
  (require rackunit)

  (define base
    (keys [(key 'left)                       (λ () 'left)]
          [(key 'x 'ctrl) (key 's 'ctrl)     (λ () 'save)]
          [(key 'p 'ctrl) (key 'up)          (λ () 'focus-up)]))

  ;; 精确查：单键 / 多键 / 前缀未到底
  (check-equal? ((keymap-ref base (list (key 'left)))) 'left)
  (check-equal? ((keymap-ref base (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save)
  (check-equal? ((keymap-ref base (list (key 'p 'ctrl) (key 'up)))) 'focus-up)
  (check-false (keymap-ref base (list (key 'x 'ctrl))))
  (check-false (keymap-ref base (list (key 'nope))))

  ;; 单步推进
  (define-values (s1 e1) (keymap-step base (key 'x 'ctrl)))
  (check-equal? s1 'prefix)
  (check-true (keymap? e1))
  (define-values (s2 e2) (keymap-step base (key 'left)))
  (check-equal? s2 'command)
  (check-equal? (e2) 'left)
  (define-values (s3 _) (keymap-step base (key 'zz)))
  (check-equal? s3 'unbound)

  ;; 合并：后表覆盖同序列
  (define user (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () 'save-as)]))
  (define m (keymap-merge (list base user)))
  (check-equal? ((keymap-ref m (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save-as)
  ;; 不冲突的续键都保留（前缀递归合并）
  (define m2 (keymap-merge (list base (keys [(key 'x 'ctrl) (key 'c 'ctrl) (λ () 'quit)]))))
  (check-equal? ((keymap-ref m2 (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save)
  (check-equal? ((keymap-ref m2 (list (key 'x 'ctrl) (key 'c 'ctrl)))) 'quit)
  ;; 前缀整体也是「同一个键」：后表用叶子覆盖前缀
  (define m3 (keymap-merge (list base (keys [(key 'x 'ctrl) (λ () 'x-only)]))))
  (check-equal? ((keymap-ref m3 (list (key 'x 'ctrl)))) 'x-only)
  (check-false (keymap-ref m3 (list (key 'x 'ctrl) (key 's 'ctrl))))

  (displayln "keymap.rkt: ok"))
