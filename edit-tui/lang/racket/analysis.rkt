#lang racket

;;; edit-tui/lang/racket/analysis.rkt —— Racket 源码语义分析（纯）
;;;
;;; 在 source.rkt 的“顶层 require / define / provide”之上，补一层**局部绑定**：
;;;   lambda / let / let-values / for / match / syntax-case / with-syntax …
;;;
;;; 目的不是实现完整的 Racket 展开器，而是给补全 / 文档提供比“扫所有词”更可靠的
;;; 本地名字集合。规则按 Racket 的绑定形式写；未知形式继续向下走，避免漏掉
;;; 内部 define。
;;;
;;; 重要：分析结果是“某个文本版本”的纯数据。跨 buffer 的缓存/依赖由
;;; workspace.rkt 负责，不在本文件做全局可变缓存。

(provide (struct-out module-analysis)
         analyze-source
         local-binding-names
         binding-names-of-forms)

(require racket/list
         racket/string
         "source.rkt")

(struct module-analysis
  (lang          ; symbol | #f
   forms         ; 顶层表单
   requires      ; 规范化后的 require / #lang 模块路径
   specs         ; 原始 require spec（保留 only-in / prefix-in …）
   definitions   ; 顶层定义名（symbol）
   provides      ; 顶层 provide 名（string，未展开 all-from-out）
   bindings)     ; 文件内所有局部绑定名（string）
  #:transparent)

;;; ════════════════ 通用遍历工具 ════════════════

(define (pair-elems x)
  (let loop ([x x])
    (cond [(null? x) '()]
          [(pair? x) (cons (car x) (loop (cdr x)))]
          [else (list x)])))

(define (distinct-symbols ss)
  (define seen (make-hasheq))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond [(hash-ref seen s #f) acc]
           [else (hash-set! seen s #t) (cons s acc)]))))

(define (symbols->strings ss)
  (distinct-strings (map symbol->string (distinct-symbols ss))))

(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond [(hash-ref seen s #f) acc]
           [else (hash-set! seen s #t) (cons s acc)]))))

;;; ════════════════ 参数 / 模式绑定 ════════════════

;; lambda 参数：x | (x y . rest) | [x default]
(define (param-names p)
  (cond
    [(symbol? p) (list p)]
    [(pair? p) (append* (for/list ([x (in-list (pair-elems p))]) (param-names x)))]
    [else '()]))

;; 模式里的绑定名。跳过构造器、字面量、_、...、?/and/or/not/app 的特殊位置。
(define (pattern-names pat [literals '()])
  (cond
    [(symbol? pat)
     (cond [(memq pat '(_ ...)) '()]
           [(memq pat literals) '()]
           [else (list pat)])]
    [(pair? pat)
     (define h (and (symbol? (car pat)) (car pat)))
     (cond
       [(eq? h 'quote) '()]
       [(eq? h '?) (append* (for/list ([x (in-list (cddr pat))]) (pattern-names x literals)))]
       [(memq h '(and or)) (append* (for/list ([x (in-list (cdr pat))]) (pattern-names x literals)))]
       [(eq? h 'not) '()]
       [(eq? h 'app) (append* (for/list ([x (in-list (cddr pat))]) (pattern-names x literals)))]
       ;; (x ...) ：重复模式
       [(and (pair? (cdr pat)) (eq? (cadr pat) '...))
        (pattern-names (car pat) literals)]
       [else
        ;; 第一个元素是构造器 / 字面量，不绑定；其余按子模式处理。
        (append* (for/list ([x (in-list (cdr pat))]) (pattern-names x literals)))])]
    [(vector? pat)
     (append* (for/list ([x (in-vector pat)]) (pattern-names x literals)))]
    [else '()]))

(define (let-binding-names b [literals '()])
  (cond
    [(symbol? b) (list b)]                  ; 单独的 id（for 子句）
    [(pair? b) (pattern-names (car b) literals)]
    [else '()]))

;; define / define-syntax 的目标：
;;   name
;;   (name args ...)
(define (define-target-names target)
  (cond
    [(symbol? target) (list target)]
    [(pair? target)
     (define head (and (symbol? (car target)) (car target)))
     (append (if head (list head) '())
             (param-names (cdr target)))]
    [else '()]))

;;; ════════════════ 表单遍历 ════════════════

(define (walk-all forms)
  (append* (for/list ([f (in-list forms)]) (walk f))))

(define (walk-body forms)
  (walk-all forms))

(define for-heads
  '(for for/list for/vector for/vector* for/hash for/hasheq for/hasheqv for/hash* for/hash*
        for/and for/or for/first for/last for/sum for/product for/fold for*/fold
        for/foldr for*/foldr for/fold/derived for*/fold/derived
        for/mutable for/foldr for/lists for*/lists))

(define (for-form? head)
  (and head (memq head for-heads) #t))

(define (for-clause-names clauses)
  (append*
   (for/list ([c (in-list clauses)])
     (cond
       [(pair? c) (let-binding-names (car c))]
       [else '()]))))

(define (walk form)
  (cond
    [(not (pair? form)) '()]
    [else
     (define head (and (symbol? (car form)) (car form)))
     (case head
       [(quote quasiquote syntax quasisyntax) '()]

       ;; ---------- 定义 ----------
       [(define define-syntax define-syntax-rule)
        (define target (and (pair? (cdr form)) (cadr form)))
        (append (define-target-names target)
                (walk-body (cddr form)))]

       [(define-values)
        (define target (and (pair? (cdr form)) (cadr form)))
        (append (param-names target)
                (walk-body (cddr form)))]

       [(define/contract define/match)
        (define target (and (pair? (cdr form)) (cadr form)))
        (append (define-target-names target)
                (walk-body (cddr form)))]

       [(struct struct* define-struct)
        (define t (and (pair? (cdr form)) (cadr form)))
        (define fields (and (pair? (cddr form)) (caddr form)))
        (append
         (if (symbol? t) (list t) '())
         (if (symbol? t)
             (list (string->symbol (string-append (symbol->string t) "?")))
             '())
         (if (and (symbol? t) (pair? fields))
             (for/list ([f (in-list fields)]
                        #:when (symbol? f))
               (string->symbol (format "~a-~a" t f)))
             '())
         (walk-body (cdddr form)))]

       ;; ---------- 函数 / 绑定 ----------
       [(lambda λ)
        (define params (and (pair? (cdr form)) (cadr form)))
        (append (param-names params) (walk-body (cddr form)))]

       [(case-lambda)
        (append*
         (for/list ([clause (in-list (cdr form))])
           (cond
             [(and (pair? clause) (pair? (car clause)))
              (append (param-names (car clause)) (walk-body (cdr clause)))]
             [else (walk clause)])))]

       [(let let* letrec let-values let*-values letrec-values)
        (define bindings (and (pair? (cdr form)) (cadr form)))
        (append
         (if (pair? bindings)
             (append* (for/list ([b (in-list bindings)]) (let-binding-names b)))
             '())
         (walk-all (if (pair? bindings) bindings '()))
         (walk-body (cddr form)))]

       [(let-syntax letrec-syntax)
        (define bindings (and (pair? (cdr form)) (cadr form)))
        (append
         (if (pair? bindings)
             (append* (for/list ([b (in-list bindings)]) (let-binding-names b)))
             '())
         (walk-all (if (pair? bindings) bindings '()))
         (walk-body (cddr form)))]

       [(letrec-syntaxes+values)
        ;; (letrec-syntaxes+values ([(id transformer) ...] [(id val) ...]) body ...)
        (define syntax-bindings (and (pair? (cdr form)) (cadr form)))
        (define value-bindings (and (pair? (cddr form)) (caddr form)))
        (append
         (if (pair? syntax-bindings)
             (append* (for/list ([b (in-list syntax-bindings)]) (let-binding-names b)))
             '())
         (if (pair? value-bindings)
             (append* (for/list ([b (in-list value-bindings)]) (let-binding-names b)))
             '())
         (walk-body (cdddr form)))]

       [(shared)
        (define bindings (and (pair? (cdr form)) (cadr form)))
        (append
         (if (pair? bindings)
             (append* (for/list ([b (in-list bindings)]) (let-binding-names b)))
             '())
         (walk-all (if (pair? bindings) bindings '()))
         (walk-body (cddr form)))]

       ;; ---------- for ----------
       [else
        (cond
          [(for-form? head)
           (define fold? (memq head '(for/fold for*/fold for/foldr for*/foldr
                                             for/fold/derived for*/fold/derived)))
           (define accs (and fold? (pair? (cdr form)) (cadr form)))
           (define clauses (if fold?
                               (and (pair? (cddr form)) (caddr form))
                               (and (pair? (cdr form)) (cadr form))))
           (define body (if fold? (cdddr form) (cddr form)))
           (append
            (if fold? (for-clause-names accs) '())
            (walk-all (if fold? accs '()))
            (for-clause-names clauses)
            (walk-all (if (list? clauses) clauses '()))
            (walk-body body))]

          ;; ---------- match / syntax ----------
          [(memq head '(match match*))
           (define clauses (cddr form))
           (append
            (walk-all (list (cadr form)))
            (append*
             (for/list ([clause (in-list clauses)])
               (cond
                 [(pair? clause)
                  (append (pattern-names (car clause))
                          (walk-body (cdr clause)))]
                 [else '()]))))]

          [(memq head '(match-lambda match-lambda*))
           (append*
            (for/list ([clause (in-list (cdr form))])
              (cond
                [(pair? clause)
                 (append (pattern-names (car clause))
                         (walk-body (cdr clause)))]
                [else '()])))]

          [(memq head '(match-let match-let* match-letrec))
           (define bindings (and (pair? (cdr form)) (cadr form)))
           (append
            (if (pair? bindings)
                (append* (for/list ([b (in-list bindings)])
                           (if (pair? b) (pattern-names (car b)) '())))
                '())
            (walk-all (if (pair? bindings) bindings '()))
            (walk-body (cddr form)))]

          [(eq? head 'match-define)
           (define pat (and (pair? (cdr form)) (cadr form)))
           (append (pattern-names pat) (walk-body (cddr form)))]

          [(eq? head 'with-syntax)
           (define bindings (and (pair? (cdr form)) (cadr form)))
           (append
            (if (pair? bindings)
                (append* (for/list ([b (in-list bindings)])
                           (if (pair? b) (pattern-names (car b)) '())))
                '())
            (walk-all (if (pair? bindings) bindings '()))
            (walk-body (cddr form)))]

          [(eq? head 'syntax-case)
           (define literals (and (pair? (cddr form)) (caddr form)))
           (define lits (if (list? literals) (filter symbol? literals) '()))
           (append*
            (for/list ([clause (in-list (cdddr form))])
              (cond
                [(pair? clause)
                 (append (pattern-names (car clause) lits)
                         (walk-body (cdr clause)))]
                [else '()])))]

          [(eq? head 'syntax-rules)
           (define literals (and (pair? (cdr form)) (cadr form)))
           (define lits (if (list? literals) (filter symbol? literals) '()))
           (append*
            (for/list ([clause (in-list (cddr form))])
              (cond
                [(pair? clause)
                 (append (pattern-names (car clause) lits)
                         (walk-body (cdr clause)))]
                [else '()])))]

          [(eq? head 'module)
           ;; (module name lang body ...)
           (walk-body (if (>= (length form) 4) (cdddr form) '()))]

          [(memq head '(begin begin0))
           (walk-body (cdr form))]

          [(memq head '(require provide))
           '()]

          ;; 未知形式：继续向下找内部 define / lambda。
          [else (walk-all (cdr form))])])]))

;;; ════════════════ 对外 ════════════════

(define (binding-names-of-forms forms)
  (symbols->strings (walk-all forms)))

(define (local-binding-names text)
  (define-values (_lang forms) (module-context text))
  (binding-names-of-forms forms))

(define (analyze-source _path text)
  (define-values (lang forms)
    (module-context text))
  (module-analysis lang
                   forms
                   (requires-of-forms lang forms)
                   (require-specs-of-forms lang forms)
                   (definitions-of-forms forms)
                   (provides-of-forms text)
                   (binding-names-of-forms forms)))
