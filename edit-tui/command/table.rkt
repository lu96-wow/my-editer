#lang racket

;;; edit-tui-rebuild/command/table.rkt —— 命令表（纯）
;;;
;;; 两层：
;;;
;;;   command-table       一张表：key-sequence -> command
;;;   command-table-stack 表的列表：用于动态遮蔽（弹窗 / 临时模式）
;;;
;;; 查找顺序：
;;;   stack 顶 → 底。某个表返回 command / prefix 就停止；
;;;   只有 unbound 才继续查下一张表。
;;;
;;; key-sequence 是任意 equal? 可比的 token 列表，例如：
;;;   (key 'x 'ctrl) (key 's 'ctrl)
;;; 本模块不关心 token 具体长什么样。
;;;
;;; 合并 / 叠加：
;;;   command-table-merge       把多张表合成一张；左边的表优先。
;;;   command-table-stack-over  把两层 stack 叠加；top 优先。
;;;
;;; 动态：
;;;   stack-push / stack-pop / stack-remove 只改 list，纯值。
;;;   弹窗可以 push 一张临时表，关闭时 pop / remove。
;;;   模态（输入栏）则直接换用另一张 stack —— 独占而不是叠加。
;;;   原因：lookup 对 unbound 会继续往下查，叠加会让全局键穿透。
;;;
;;; 表只负责匹配，不负责“命令是什么”。命令值可以是过程 / 结构 / id。

(provide (struct-out command-table)
         (struct-out command-table-stack)
         command-table-empty
         command-table-add
         command-table-from-bindings
         command-table-bindings
         command-table-merge
         command-table-lookup
         command-table-prefix?
         command-table-exact?

         command-table-stack-empty
         command-table-stack-from-tables
         command-table-stack-tables
         command-table-stack-over
         command-table-stack-push
         command-table-stack-pop
         command-table-stack-remove
         command-table-stack-lookup

         keys)

;;; ════════════════ 单表 ════════════════

(struct binding (value) #:transparent)
(struct node (children binding) #:transparent)
(struct command-table (root) #:transparent)
;; root : node

(define (make-node [children (hash)] [binding #f])
  (node children binding))

(define command-table-empty
  (command-table (make-node)))

(define (check-seq who seq)
  (unless (and (list? seq) (pair? seq))
    (error who "key-sequence 要非空 list：~a" seq)))

;; 插入 / 覆盖一条 binding。
(define (command-table-add table seq value)
  (check-seq 'command-table-add seq)
  (define (go n seq)
    (define k (car seq))
    (define children (node-children n))
    (define child (or (hash-ref children k #f) (make-node)))
    (define child*
      (if (null? (cdr seq))
          (struct-copy node child [binding (binding value)])
          (go child (cdr seq))))
    (struct-copy node n
                 [children (hash-set children k child*)]))
  (command-table (go (command-table-root table) seq)))

;; bindings : (listof (list key-sequence value))
(define (command-table-from-bindings bindings)
  (for/fold ([t command-table-empty]) ([b (in-list bindings)])
    (command-table-add t (car b) (cadr b))))

;; → (listof (list key-sequence value))，按 DFS 顺序。
(define (command-table-bindings table)
  (define out '())
  (define (walk n rev)
    (define b (node-binding n))
    (when b
      (set! out (cons (list (reverse rev) (binding-value b)) out)))
    (for ([(k child) (in-hash (node-children n))])
      (walk child (cons k rev))))
  (walk (command-table-root table) '())
  (reverse out))

;; 多张表合成一张；左边的表优先。
(define (command-table-merge . tables)
  (for/fold ([acc command-table-empty])
            ([t (in-list (reverse tables))])
    (for/fold ([acc acc])
              ([b (in-list (command-table-bindings t))])
      (command-table-add acc (car b) (cadr b)))))

;; → (values 'command value) | (values 'prefix #f) | (values 'unbound #f)
(define (command-table-lookup table seq)
  (define (walk n seq)
    (cond
      [(null? seq)
       (define b (node-binding n))
       (cond
         [b (values 'command (binding-value b))]
         [(positive? (hash-count (node-children n))) (values 'prefix #f)]
         [else (values 'unbound #f)])]
      [else
       (define child (hash-ref (node-children n) (car seq) #f))
       (if child
           (walk child (cdr seq))
           (values 'unbound #f))]))
  (walk (command-table-root table) seq))

(define (command-table-exact? table seq)
  (define-values (st _v) (command-table-lookup table seq))
  (eq? st 'command))

(define (command-table-prefix? table seq)
  (define-values (st _v) (command-table-lookup table seq))
  (eq? st 'prefix))

;;; ════════════════ 表 stack（动态遮蔽） ════════════════

(struct command-table-stack (tables) #:transparent)
;; tables : (listof command-table)，第一个 = 最上层

(define command-table-stack-empty
  (command-table-stack '()))

(define (command-table-stack-from-tables tables)
  (unless (list? tables)
    (error 'command-table-stack-from-tables "tables 要是 list：~a" tables))
  (for ([t (in-list tables)])
    (unless (command-table? t)
      (error 'command-table-stack-from-tables "元素要是 command-table：~a" t)))
  (command-table-stack tables))

;; 叠两层 stack：top 的表全在 bottom 之上（等价于 append 两边的 tables）。
;; 加法遮蔽用这个；替换整栈（模态）直接持有另一张 stack，不要调用它。
(define (command-table-stack-over top bottom)
  (unless (command-table-stack? top)
    (error 'command-table-stack-over "top 要是 command-table-stack：~a" top))
  (unless (command-table-stack? bottom)
    (error 'command-table-stack-over "bottom 要是 command-table-stack：~a" bottom))
  (command-table-stack-from-tables
   (append (command-table-stack-tables top)
           (command-table-stack-tables bottom))))

(define (command-table-stack-push stack table)
  (unless (command-table? table)
    (error 'command-table-stack-push "table 要是 command-table：~a" table))
  (struct-copy command-table-stack stack
               [tables (cons table (command-table-stack-tables stack))]))

(define (command-table-stack-pop stack)
  (define ts (command-table-stack-tables stack))
  (struct-copy command-table-stack stack
               [tables (if (pair? ts) (cdr ts) '())]))

(define (command-table-stack-remove stack table)
  (struct-copy command-table-stack stack
               [tables (for/list ([t (in-list (command-table-stack-tables stack))]
                                  #:unless (eq? t table))
                         t)]))

;; 顶层表先查；只有 unbound 才落到下一层。
(define (command-table-stack-lookup stack seq)
  (let loop ([ts (command-table-stack-tables stack)])
    (cond
      [(null? ts) (values 'unbound #f)]
      [else
       (define-values (st v) (command-table-lookup (car ts) seq))
       (if (eq? st 'unbound)
           (loop (cdr ts))
           (values st v))])))

;;; ════════════════ 构造 DSL ════════════════

;; keys：[key ... value] ... —— 最后一格是命令值，前面是 key-sequence。
(define-syntax keys
  (syntax-rules ()
    [(_ [seq ... value] ...)
     (command-table-from-bindings
      (list (list (list seq ...) value) ...))]))
