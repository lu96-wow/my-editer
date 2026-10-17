#lang racket

;;; base/keymap.rkt —— 通用 token → 值 的前缀表（纯，不依赖 command 层）
;;;
;;; 与旧 command/keymap.rkt 的区别：叶子是**任意值**，不要求是 command。
;;; 于是 rebuild 可以把 `command-spec`、测试用的符号、菜单项都放进同一结构；
;;; 由 dispatch 决定叶子值怎么解释。
;;;
;;;   keymap : trie
;;;     叶子   (binding value)
;;;     子树   keymap
;;;
;;; 查找：
;;;   (keymap-lookup km seq)
;;;     → (values 'leaf    value)
;;;     → (values 'prefix  #f)
;;;     → (values 'unbound #f)
;;;
;;; 构造：
;;;   (keys [tok ... value] ...)   最后一格是值，前面是 token 序列
;;;   (keymap-add km seq value)
;;;
;;; token 由调用方提供（command/key.rkt、command/mouse.rkt），本模块只要求 equal? 可比。

(provide (struct-out keymap)
         (struct-out binding)
         empty-keymap
         binding-value
         keymap-add
         keymap-from-bindings
         keymap-lookup
         keymap-ref
         keymap-prefix?
         keymap-navigate
         keys)

(struct binding (value) #:transparent)
;; value : any/c（通常 command-spec；也可以是菜单项 / 测试值）

(struct keymap (bindings) #:transparent)
;; bindings : (hash/c any/c (or/c keymap? binding?))

(define empty-keymap (keymap (hash)))

;; 插入一条 seq → 值。路径上的旧叶子 / 旧子树按“后插覆盖”处理。
(define (keymap-add km seq value)
  (unless (pair? seq)
    (error 'keymap-add "序列要是非空 token 列表，得到 ~a" seq))
  (define (go h seq)
    (define k (car seq))
    (if (null? (cdr seq))
        (hash-set h k (binding value))
        (let* ([sub (hash-ref h k #f)]
               [sub* (if (keymap? sub) sub empty-keymap)])
          (hash-set h k (keymap (go (keymap-bindings sub*) (cdr seq)))))))
  (keymap (go (keymap-bindings km) seq)))

;; 单步查一个 token → 子树 | binding | #f
(define (keymap-step km tok)
  (and km (hash-ref (keymap-bindings km) tok #f)))

;; 精确查完整序列 → value | #f（序列是前缀但没到底 → #f）
(define (keymap-ref km seq)
  (let loop ([cur km] [seq seq])
    (cond [(null? seq) (and (binding? cur) (binding-value cur))]
          [(not (keymap? cur)) #f]
          [else (loop (keymap-step cur (car seq)) (cdr seq))])))

;; 沿 seq 走到节点 → 子树 | #f。空 seq 得到根。
(define (keymap-navigate km seq)
  (let loop ([cur km] [seq seq])
    (cond [(null? seq) (and (keymap? cur) cur)]
          [(not (keymap? cur)) #f]
          [else (define e (keymap-step cur (car seq)))
                (and e (loop e (cdr seq)))])))

;; 这条序列是不是某条更长绑定的前缀？
(define (keymap-prefix? km seq) (and (keymap-navigate km seq) #t))

;; 查完整序列，三态返回。value 允许是 #f（所以不能靠 keymap-ref 的真假判断）。
(define (keymap-lookup km seq)
  (let loop ([cur km] [seq seq])
    (cond
      [(null? seq) (if (binding? cur)
                       (values 'leaf (binding-value cur))
                       (values 'prefix #f))]
      [(keymap? cur)
       (define e (keymap-step cur (car seq)))
       (if e (loop e (cdr seq)) (values 'unbound #f))]
      [else (values 'unbound #f)])))

;;; ---------- 构造 DSL ----------

;; keys：[seq … value] —— 最后一格是值，其余是 token 序列。
(define-syntax keys
  (syntax-rules ()
    [(_ [seq ... value] ...)
     (keymap-from-bindings (list (list (list seq ...) value) ...))]))

(define (keymap-from-bindings binds)
  (for/fold ([km empty-keymap]) ([b (in-list binds)])
    (keymap-add km (car b) (cadr b))))
