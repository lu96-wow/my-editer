#lang racket

;;; command/keymap.rkt —— 键表（纯）：token 序列 → 过程
;;;
;;; token 是不透明、equal? 可比的值（键令牌、鼠标令牌…）。表是一棵 trie：
;;;     叶子   过程     命中即执行
;;;     子树   keymap   前缀，继续读键
;;;
;;; 组合 `keymap-merge`：按顺序折叠，**后加入的表覆盖前面的**——
;;;   · 同一路径（同序列）→ 后面的叶子替换前面的；
;;;   · 一个键下两边都是子树 → 递归合并（各自不冲突的续键都保留）；
;;;   · 一边叶子一边子树 → 后面的整体替换前面的（前缀也是「同键」）。
;;;
;;; 构造 DSL `keys`：每条绑定写成一对方括号，最后一格是过程，前面是要按的 token。
;;;
;;;     (keys [(key 'left)                 (λ () …)]
;;;           [(mouse 'press 'left)        (λ () …)])
;;;
;;; 宿主读到事件后调 `keymap-step` 推进；`empty-keymap` 是空表。

(provide (struct-out keymap)
         empty-keymap
         keymap-set keymap-ref keymap-lookup keymap-step
         keymap-merge
         keys)

;; token 由调用方给：键用 (key …)，鼠标用 (mouse …)。表本身不关心 token 类型。

(struct keymap (bindings) #:transparent)
;; bindings : (hash/c any/c (or/c keymap? procedure?))   ; 键 = 任意 equal? 可比 token

(define empty-keymap (keymap (hash)))

;; 插入一条 seq → proc。路径上的旧叶子 / 旧子树按「后插覆盖」处理。
(define (keymap-set km seq proc)
  (unless (pair? seq)
    (error 'keymap-set "序列要是非空 token 列表，得到 ~a" seq))
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
