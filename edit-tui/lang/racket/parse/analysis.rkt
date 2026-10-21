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
         (struct-out form-entry)
         analyze-source
         analysis-edit
         local-binding-names
         binding-names-of-forms)

(require racket/list
         racket/string
         "../base/edit.rkt"
         "source.rkt")

(struct form-entry
  (start-line    ; 0-based，含
   end-line      ; 0-based，不含
   form)         ; reader datum
  #:transparent)

(struct module-analysis
  (lang          ; symbol | #f
   forms         ; 顶层表单
   requires      ; 规范化后的 require / #lang 模块路径
   specs         ; 原始 require spec（保留 only-in / prefix-in …）
   definitions   ; 顶层定义名（symbol）
   provides      ; 顶层 provide 名（string，未展开 all-from-out）
   bindings      ; 文件内所有局部绑定名（string）
   entries)      ; (listof form-entry) | #f（#f = 不支持增量，回落全量）
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

;;; ════════════════ reader：form + 行区间 ════════════════

(define (text-line-starts text)
  (define n (string-length text))
  (let loop ([i 0] [acc (list 0)])
    (cond
      [(>= i n) (list->vector (reverse acc))]
      [(char=? (string-ref text i) #\newline)
       (loop (add1 i) (cons (add1 i) acc))]
      [else (loop (add1 i) acc)])))

;; 最大 start <= pos 的下标。
(define (pos->line starts pos)
  (let loop ([lo 0] [hi (sub1 (vector-length starts))] [best 0])
    (cond
      [(> lo hi) best]
      [else
       (define mid (quotient (+ lo hi) 2))
       (cond
         [(<= (vector-ref starts mid) pos) (loop (add1 mid) hi mid)]
         [else (loop lo (sub1 mid) best)])])))

(define (line-start-offset starts line)
  (cond
    [(< line 0) 0]
    [(>= line (vector-length starts)) (vector-ref starts (sub1 (vector-length starts)))]
    [else (vector-ref starts line)]))

(define (entry-from-syntax text body-offset starts stx start-pos end-pos)
  (define pos (+ body-offset (or (syntax-position stx) start-pos)))
  (define span (or (syntax-span stx) (- end-pos start-pos)))
  (define start-line (pos->line starts pos))
  (define end-line
    (cond
      [(<= span 0) (add1 start-line)]
      [else (add1 (pos->line starts (sub1 (+ pos span))))]))
  (form-entry start-line end-line (syntax->datum stx)))

;; 从 text 的 start-offset 开始读 form。
;; stop-entry = 期望在尾部重新遇到的旧 form-entry；遇到它之前就停。
;; → (values entries matched? matched-start-line)
(define (read-entries-from text start-offset #:stop-entry [stop-entry #f])
  (define-values (body body-offset) (reader-body+offset text))
  (define starts (text-line-starts text))
  (define in (open-input-string body))
  (define rel-start (max 0 (min (- start-offset body-offset) (string-length body))))
  (file-position in rel-start)
  (let loop ([acc '()])
    (define start-pos (file-position in))
    (define stx
      (with-handlers ([exn:fail? (lambda (_) eof)])
        (read-syntax 'racket in)))
    (cond
      [(eof-object? stx) (values (reverse acc) #f #f)]
      [else
       (define end-pos (file-position in))
       (define e (entry-from-syntax text body-offset starts stx start-pos end-pos))
       (cond
         [(and stop-entry
               (equal? (form-entry-form e) (form-entry-form stop-entry)))
          (values (reverse acc) #t (form-entry-start-line e))]
         [else (loop (cons e acc))])])))

(define (read-all-entries text)
  (define-values (entries _matched? _line)
    (read-entries-from text 0))
  entries)

;;; ════════════════ 行映射 ════════════════

(define (sort-edits edits)
  (sort edits < #:key line-edit-old-start))

;; 旧行 -> 新行。只用于定位重解析起点；越界由调用方 clamp。
(define (map-old-line line edits)
  (for/fold ([ln line]) ([e (in-list (sort-edits edits))])
    (define old-count (- (line-edit-old-end e) (line-edit-old-start e)))
    (define new-count (- (line-edit-new-end e) (line-edit-new-start e)))
    (cond
      [(<= (line-edit-old-end e) ln)
       (+ ln (- new-count old-count))]
      [(< (line-edit-old-start e) ln)
       (+ (line-edit-new-start e)
          (min (max 0 (- ln (line-edit-old-start e))) new-count))]
      [else ln])))

(define (entry-dirty? e edits)
  (for/or ([ed (in-list edits)])
    (define old-start (line-edit-old-start ed))
    (define old-end (line-edit-old-end ed))
    (define lo (if (= old-start old-end) old-start old-start))
    (define hi (if (= old-start old-end) (add1 old-start) old-end))
    (and (< (form-entry-start-line e) hi)
         (< lo (form-entry-end-line e)))))

(define (shift-entry e delta)
  (struct-copy form-entry e
               [start-line (+ (form-entry-start-line e) delta)]
               [end-line (+ (form-entry-end-line e) delta)]))

(define (binding-names-of-forms forms)
  (symbols->strings (walk-all forms)))

(define (local-binding-names text)
  (define-values (_lang forms) (module-context text))
  (binding-names-of-forms forms))

;;; ════════════════ 聚合 ════════════════

(define (entries->forms entries)
  (for/list ([e (in-list entries)]) (form-entry-form e)))

(define (make-analysis lang entries)
  (define forms (entries->forms entries))
  (module-analysis lang
                   forms
                   (requires-of-forms lang forms)
                   (require-specs-of-forms lang forms)
                   (definitions-of-forms forms)
                   (provides-of-forms* forms)
                   (binding-names-of-forms forms)
                   entries))

(define (analyze-source _path text)
  (define lang (module-lang text))
  (define entries (read-all-entries text))
  (define forms (entries->forms entries))
  ;; 无 #lang 但顶层是 (module …) 的老写法：先用全量逻辑，增量暂时关闭。
  (cond
    [(and (not lang)
          (pair? forms)
          (pair? (car forms))
          (eq? (car (car forms)) 'module))
     (define-values (lang* forms*) (module-context text))
     (module-analysis lang* forms*
                      (requires-of-forms lang* forms*)
                      (require-specs-of-forms lang* forms*)
                      (definitions-of-forms forms*)
                      (provides-of-forms text)
                      (binding-names-of-forms forms*)
                      #f)]
    [else (make-analysis lang entries)]))

;;; ════════════════ 增量解析 ════════════════

;; 旧 analysis + 新文本 + line-edit -> 新 analysis。
;; 策略：
;;   1. 找受旧脏行影响的顶层 form-entry；
;;   2. 从第一个受影响 form 附近重新 read；
;;   3. 读到尾部第一个未变化的旧 form 时收敛，后续 form-entry 只做行号平移；
;;   4. 边界/reader 错误时回落到全量 analyze-source。
(define (analysis-edit old path text edits)
  (cond
    [(null? edits) old]
    [(not (module-analysis-entries old)) (analyze-source path text)]
    [else
     (define entries (module-analysis-entries old))
     (define hit-indices
       (for/list ([e (in-list entries)] [i (in-naturals)]
                  #:when (entry-dirty? e edits))
         i))
     (cond
       [(null? hit-indices)
        ;; 改在 form 外的空白/注释：保守全量，避免漏掉新增顶层 form。
        (analyze-source path text)]
       [else
        (define first-i (car hit-indices))
        (define last-i (car (reverse hit-indices)))
        (define before (take entries first-i))
        (define first-entry (list-ref entries first-i))
        (define after (drop entries (add1 last-i)))
        (define stop-entry (and (pair? after) (car after)))
        (define new-start-line
          (map-old-line (form-entry-start-line first-entry) edits))
        (define starts (text-line-starts text))
        (define start-offset (line-start-offset starts new-start-line))
        (define-values (region matched? matched-line)
          (read-entries-from text start-offset #:stop-entry stop-entry))
        (define tail
          (cond
            [matched?
             (define delta (- matched-line (form-entry-start-line stop-entry)))
             (if (zero? delta)
                 after
                 (for/list ([e (in-list after)]) (shift-entry e delta)))]
            [else '()]))
        ;; 若读失败，region 可能为空；保守全量。
        (cond
          [(and (not matched?) (null? region) (pair? after))
           (analyze-source path text)]
          [else
           (make-analysis (module-analysis-lang old)
                          (append before region tail))])])]))
