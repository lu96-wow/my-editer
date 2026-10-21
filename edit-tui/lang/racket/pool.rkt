#lang racket

;;; edit-tui/lang/racket/pool.rkt —— 补全候选来源（纯）
;;;
;;; 关键：把 require **原始 spec** 按结构算出**最终绑定名**（已套用 only-in / except-in /
;;; prefix-in / rename-in / prefix-rename-in / 相位包装）。于是
;;;   (prefix-in l: racket/list)   → l:first …
;;;   (only-in racket/list first)  → first
;;;   (rename-in racket/list [first f]) → f + 其它未改名导出
;;;   (require "local.rkt")        → 本地文件的 (provide …)（打开的用**当前缓冲区文本**）
;;; 对任意编辑中的文本是全函数：非法 spec 一律 '()。
;;;
;;; 移植自 edit/plugins/lang/pool.rkt（去掉此项目不用的 completion-pool / filter-pool）。

(provide module-exports distinct-strings
         spec-names spec-local-paths spec-binding-of)

(require racket/list
         racket/path
         racket/string
         "source.rkt")

;;; ================= 模块导出缓存 =================

(define exports-cache (make-hash))       ; module-path -> (listof string)

;; 一个模块的导出名（值 + 语法，所有 phase），字符串形式。
;; 先 module-declared? 声明（路径形式的模块 / 未加载的需先声明，否则 module->exports 报
;; "unknown module"）；失败一律当空。
(define (module-exports m)
  (hash-ref! exports-cache m
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) '())])
        (module-declared? m #t)
        (define-values (vars stx) (module->exports m))
        (for*/list ([p (in-list (append (or vars '()) (or stx '())))]
                    [id (in-list (map car (cdr p)))])
          (symbol->string id))))))

;;; ================= 去重 =================

;; 保持首次出现顺序的字符串去重（哈希 O(n)）。
(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond [(hash-ref seen s #f) acc]
           [else (hash-set! seen s #t) (cons s acc)]))))

;;; ================= require spec → 引入的绑定名 =================

;; specs : 原始 require spec；open : hash 绝对路径字符串 -> 该文档**当前缓冲区文本** | #f。
;; 打开的本地文件优先用缓冲区（可解析半成品），否则 module-exports 磁盘模块。
(define (spec-names s base-dir [open #f])
  (with-handlers ([exn:fail? (lambda (_) '())])
    (cond
      [(symbol? s) (module-exports s)]
      [(string? s)
       (define p (local-module-path s base-dir))
       (cond
         [(not p) '()]
         [(and open (hash-ref open (path->string p) #f)) => provides-of-forms]
         [else (module-exports p)])]
      [(pair? s)
       (define h (and (symbol? (car s)) (car s)))
       (cond
         [(eq? h 'only-in)
          (map symbol->string (filter symbol? (cddr s)))]
         [(eq? h 'except-in)
          (remove* (map symbol->string (filter symbol? (cddr s)))
                   (spec-names (cadr s) base-dir open) string=?)]
         [(eq? h 'prefix-in)
          (define p (if (symbol? (cadr s)) (symbol->string (cadr s)) ""))
          (for/list ([n (in-list (spec-names (caddr s) base-dir open))]) (string-append p n))]
         [(eq? h 'rename-in)
          (spec-renames (cadr s) (cddr s) "" base-dir open)]
         [(eq? h 'prefix-rename-in)
          (define p (if (symbol? (cadr s)) (symbol->string (cadr s)) ""))
          (spec-renames (caddr s) (cdddr s) p base-dir open)]
         [(memq h '(for-syntax for-template for-label)) (spec-names (cadr s) base-dir open)]
         [(eq? h 'for-meta) (append* (for/list ([x (in-list (cddr s))]) (spec-names x base-dir open)))]
         [(eq? h 'combine-in) (append* (for/list ([x (in-list (cdr s))]) (spec-names x base-dir open)))]
         [(memq h '(lib planet)) (module-exports s)]
         [(eq? h 'quote) (spec-names (cadr s) base-dir open)]
         [else '()])]
      [else '()])))

;; 字符串模块路径 → 绝对路径；空串 → #f。
(define (local-module-path s base-dir)
  (if (zero? (string-length s))
      #f
      (let ([p (string->path s)])
        (path->complete-path (if (absolute-path? p) p (build-path base-dir p))))))

;; spec 里引用的本地文件（字符串 spec，含包装内）→ (listof 绝对路径字符串)。
(define (spec-local-paths s base-dir)
  (cond
    [(string? s) (define p (local-module-path s base-dir))
                 (if p (list (path->string p)) '())]
    [(pair? s)
     (define h (and (symbol? (car s)) (car s)))
     (cond
       [(memq h '(only-in except-in rename-in)) (spec-local-paths (cadr s) base-dir)]
       [(memq h '(prefix-in prefix-rename-in)) (spec-local-paths (caddr s) base-dir)]
       [(memq h '(for-syntax for-template for-label)) (spec-local-paths (cadr s) base-dir)]
       [(eq? h 'for-meta) (append* (for/list ([x (in-list (cddr s))]) (spec-local-paths x base-dir)))]
       [(eq? h 'combine-in) (append* (for/list ([x (in-list (cdr s))]) (spec-local-paths x base-dir)))]
       [(eq? h 'quote) (spec-local-paths (cadr s) base-dir)]
       [else '()])]
    [else '()]))

;; rename：显式 [old new] → new；其余导出名保留（加前缀 p）。
(define (spec-renames mod-spec renames p base-dir open)
  (define base (spec-names mod-spec base-dir open))
  (define rs (for/list ([r (in-list renames)]
                        #:when (and (pair? r) (>= (length r) 2)))
               (cons (car r) (cadr r))))
  (define renamed (for/list ([r (in-list rs)]) (string-append p (symbol->string (cdr r)))))
  (append renamed
          (for/list ([n (in-list (remove* (for/list ([r (in-list rs)]) (symbol->string (car r)))
                                          base string=?))])
            (string-append p n))))

;;; ================= 候选名 → 来源（prefix-in / rename-in 反查） =================

;; specs 里找 name 的来源 → (list leaf-module original-name) | #f。
;; open : hash 绝对路径字符串 -> 已打开文档的当前缓冲区文本（同 spec-names，解本地文件用）。
(define (spec-binding-of name specs base-dir [open #f])
  (for/or ([s (in-list specs)]) (spec-binding-in name s base-dir open)))

(define (spec-binding-in name s base-dir [open #f])
  (cond
    ;; 库：确实是该模块的导出才认领（不无条件挂到第一个 require）。
    [(symbol? s) (and (member name (spec-names s base-dir open)) (list s name))]
    ;; 本地文件：打开的用缓冲区 provides，否则磁盘模块（同正向 spec-names）。
    [(string? s) (define p (local-module-path s base-dir))
                 (and p (member name (spec-names s base-dir open)) (list p name))]
    [(pair? s)
     (define h (and (symbol? (car s)) (car s)))
     (define (rec spec) (spec-binding-in name spec base-dir open))
     (define (ids from) (for/list ([x (in-list from)] #:when (symbol? x)) (symbol->string x)))
     (cond
       [(eq? h 'only-in)
        (and (member name (ids (cddr s))) (list (leaf-module (cadr s) base-dir) name))]
       [(eq? h 'except-in)
        (and (not (member name (ids (cddr s)))) (rec (cadr s)))]
       [(eq? h 'prefix-in)
        (define p (if (symbol? (cadr s)) (symbol->string (cadr s)) ""))
        (and (string-prefix? name p)
             (let ([b (spec-binding-in (substring name (string-length p)) (caddr s) base-dir open)])
               (and b (list (car b) (cadr b)))))]
       [(eq? h 'rename-in)
        (define r (for/first ([x (in-list (cddr s))]
                              #:when (and (pair? x) (>= (length x) 2)
                                          (eq? (cadr x) (string->symbol name))))
                   x))
        (cond [r (list (leaf-module (cadr s) base-dir) (symbol->string (car r)))]
              [else (rec (cadr s))])]
       [(eq? h 'prefix-rename-in)
        (define p (if (symbol? (cadr s)) (symbol->string (cadr s)) ""))
        (and (string-prefix? name p)
             (let ([b (spec-binding-in (substring name (string-length p)) (caddr s) base-dir open)])
               (and b (list (car b) (cadr b)))))]
       [(memq h '(for-syntax for-template for-label)) (rec (cadr s))]
       [(eq? h 'for-meta) (for/or ([x (in-list (cddr s))]) (spec-binding-in name x base-dir open))]
       [(eq? h 'combine-in) (for/or ([x (in-list (cdr s))]) (spec-binding-in name x base-dir open))]
       [(memq h '(lib planet)) (and (member name (spec-names s base-dir open)) (list s name))]
       [(eq? h 'quote) (rec (cadr s))]
       [else #f])]
    [else #f]))

;; spec 最内层模块路径（剥掉 only/except/prefix/rename/相位包装）。
(define (leaf-module spec base-dir)
  (cond
    [(symbol? spec) spec]
    [(string? spec) (or (local-module-path spec base-dir) spec)]
    [(pair? spec)
     (define h (and (symbol? (car spec)) (car spec)))
     (cond
       [(memq h '(only-in except-in rename-in)) (leaf-module (cadr spec) base-dir)]
       [(memq h '(prefix-in prefix-rename-in)) (leaf-module (caddr spec) base-dir)]
       [(memq h '(for-syntax for-template for-label)) (leaf-module (cadr spec) base-dir)]
       [(eq? h 'for-meta) (and (pair? (cddr spec)) (leaf-module (cadr (cddr spec)) base-dir))]
       [(eq? h 'quote) (leaf-module (cadr spec) base-dir)]
       [else spec])]
    [else spec]))
