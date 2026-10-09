#lang racket

;;; edit/plugin/analysis/tools/forest.rkt —— 扁平 token → token forest（纯）
;;;
;;; 把 (listof token) 解析成一棵**轻量结构树**（不展开宏），供：
;;;   · form head（`(define …)` 的 `define`）
;;;   · 最内层 enclosing list
;;;   · #; sexp-comment 区间
;;; 节点：
;;;   leaf   —— 一个 token
;;;   group  —— 平衡括号段（open token + children + close token | #f + end）
;;;   prefix —— quote 家族 / #; 前缀 + 其后的可跳节点 + 操作数
;;;   forest —— 顶层节点序列
;;;
;;; 白空格 / 注释 / 完整的 #; 段视为**可跳**；括号不平衡不崩（close = #f）。
;;; 本模块不依赖 core / session / tui。

(require "span.rkt")

(provide (struct-out forest) (struct-out group) (struct-out leaf) (struct-out prefix)
         build-forest
         node-start node-end node-span node-children node-skippable?
         forest-enclosing-group forest-form-head forest-sexp-comment-spans)

;;; ---------- 节点 ----------

(struct leaf (token) #:transparent)
(struct group (open children close end) #:transparent)   ; close : token | #f
(struct prefix (token skippable child end) #:transparent) ; child : node | #f
(struct forest (nodes) #:transparent)

(define (node-start n)
  (cond [(leaf? n) (span-start (token-span (leaf-token n)))]
        [(group? n) (span-start (token-span (group-open n)))]
        [(prefix? n) (span-start (token-span (prefix-token n)))]
        [else (error 'node-start "未知节点: ~a" n)]))

(define (node-end n)
  (cond [(leaf? n) (span-end (token-span (leaf-token n)))]
        [(group? n) (group-end n)]
        [(prefix? n) (prefix-end n)]
        [else (error 'node-end "未知节点: ~a" n)]))

(define (node-span n) (span (node-start n) (node-end n)))

(define (node-children n)
  (cond [(leaf? n) '()]
        [(group? n) (group-children n)]
        [(prefix? n) (if (prefix-child n)
                         (append (prefix-skippable n) (list (prefix-child n)))
                         (prefix-skippable n))]
        [else '()]))

;;; ---------- 可跳 ----------

(define (skippable-type? t) (memq t '(white-space comment)))
(define (sexp-comment-node? n)
  (and (prefix? n) (eq? 'sexp-comment (token-type (prefix-token n)))))
(define (node-skippable? n)
  (or (and (leaf? n) (skippable-type? (token-type (leaf-token n))))
      (sexp-comment-node? n)))

;;; ---------- 解析 ----------

(define (build-forest tokens)
  (define v (list->vector tokens))
  (forest (parse-forest v 0 (vector-length v))))

(define (token-at v idx) (and (< idx (vector-length v)) (vector-ref v idx)))

(define (parse-forest v start end)
  (let loop ([idx start] [acc '()])
    (cond
      [(>= idx end) (reverse acc)]
      [else
       (define-values (n ni) (parse-node v idx))
       (loop ni (cons n acc))])))

;; 收集可跳节点（白空格 / 注释 / 完整 #; 段）→ (values nodes next-idx)
(define (parse-skippable v idx)
  (let loop ([idx idx] [acc '()])
    (define t (token-at v idx))
    (cond
      [(not t) (values (reverse acc) idx)]
      [(skippable-type? (token-type t)) (loop (add1 idx) (cons (leaf t) acc))]
      [(eq? 'sexp-comment (token-type t))
       (define-values (n ni) (parse-node v idx))
       (loop ni (cons n acc))]
      [else (values (reverse acc) idx)])))

;; → (values node next-idx)
(define (parse-node v idx)
  (define t (vector-ref v idx))
  (case (token-type t)
    [(quote quasiquote unquote unquote-splicing
            syntax-quote syntax-quasiquote syntax-unquote syntax-unquote-splicing
            sexp-comment)
     (parse-prefix v idx t)]
    [(open-paren) (parse-group v (add1 idx) t '())]
    [else (values (leaf t) (add1 idx))]))

(define (parse-prefix v idx ptok)
  (define-values (skippables next) (parse-skippable v (add1 idx)))
  (define t (token-at v next))
  (cond
    [(not t)
     (define e (if (pair? skippables)
                   (node-end (last skippables))
                   (span-end (token-span ptok))))
     (values (prefix ptok skippables #f e) next)]
    [else
     (define-values (child ni) (parse-node v next))
     (values (prefix ptok skippables child (node-end child)) ni)]))

(define (parse-group v idx open children)
  (define t (token-at v idx))
  (cond
    [(not t)
     (define e (if (null? children)
                   (span-end (token-span open))
                   (node-end (car children))))
     (values (group open (reverse children) #f e) idx)]
    [(eq? 'close-paren (token-type t))
     (values (group open (reverse children) t (span-end (token-span t))) (add1 idx))]
    [else
     (define-values (child ni) (parse-node v idx))
     (parse-group v ni open (cons child children))]))

;;; ---------- 结构查询 ----------

(define (node-contains-pos? n pos)
  (and (<= (node-start n) pos) (< pos (node-end n))))

;; pos 处从内到外的祖先链（首 = 最内层节点，末 = 顶层）。pos 不在任何节点内 → #f。
(define (ancestors-at-pos f pos)
  (define (search n path)
    (define next (for/first ([c (in-list (node-children n))]
                             #:when (node-contains-pos? c pos))
                   c))
    (if next (search next (cons n path)) (cons n path)))
  (for/first ([n (in-list (forest-nodes f))] #:when (node-contains-pos? n pos))
    (search n '())))

;; pos 处**最内层**的 group。
(define (forest-enclosing-group f pos)
  (define anc (ancestors-at-pos f pos))
  (and anc (for/first ([n (in-list anc)] #:when (group? n)) n)))

;; 最内层 group 的 form head（第一个非可跳的 symbol 叶）。
(define (forest-form-head f pos)
  (define g (forest-enclosing-group f pos))
  (and g
       (>= pos (span-end (token-span (group-open g))))
       (for/first ([c (in-list (group-children g))]
                   #:when (and (not (node-skippable? c))
                               (leaf? c)
                               (eq? 'symbol (token-type (leaf-token c)))))
         (token-span (leaf-token c)))))

;; 所有 #; sexp-comment 段的区间（嵌套的不重复计）。
(define (forest-sexp-comment-spans f)
  (define out '())
  (define (walk n)
    (cond [(sexp-comment-node? n) (set! out (cons (node-span n) out))]
          [else (for-each walk (node-children n))]))
  (for-each walk (forest-nodes f))
  (reverse out))
