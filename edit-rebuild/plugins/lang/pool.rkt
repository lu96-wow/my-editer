#lang racket

;;; edit-rebuild/plugins/lang/pool.rkt —— 补全候选池（纯；模块导出 / 本地定义 / 文档词）
;;;
;;; 候选来源（并集、去重、按前缀过滤、排序）：
;;;   1) 候选模块（#lang 语言 + 各 require）的导出（module->exports）；
;;;   2) 文件里顶层定义的名字（lang/source 扫出来）；
;;;   3) 文件里出现过的词（core/lex 扫出来；dabbrev 式）。
;;;
;;; 自动补全每个字符都会过滤一次：把「候选池」与「按前缀过滤」拆开，
;;; 一次补全会话只建一次池，之后只 filter-pool。

(provide completion-pool filter-pool distinct-strings
         module-exports document-words spec-names spec-local-paths)

(require racket/list
         racket/path
         racket/string
         "../../core/face/lex.rkt"
         "source.rkt")

;;; ================= 缓存 =================

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

;;; ================= 池 =================

;; 保持首次出现顺序的字符串去重。用哈希 O(n)；remove-duplicates 是 O(n²)，
;; 大文件（几千行 → 上万词）建池会因此慢上百 ms。
(define (distinct-strings ss)
  (define seen (make-hash))
  (define rev
    (for/fold ([acc '()]) ([s (in-list ss)])
      (cond [(hash-ref seen s #f) acc]
            [else (hash-set! seen s #t) (cons s acc)])))
  (reverse rev))

;; 候选池：各候选模块导出 + 本地定义 + 出现过的词（去重、未排序）。
;; 模块列表应含文件的语言基座；调用方负责补齐（无 lang 无 require 时可给 '()）。
(define (completion-pool #:modules [mods '()] #:locals [locals '()] #:words [words '()])
  (distinct-strings
   (append (append* (for/list ([m (in-list mods)]) (module-exports m)))
           (map symbol->string locals)
           words)))

;; 文件里出现过的词（去重）。单字符词噪声大，默认只收 >= min-length 个字符。
(define (document-words text #:min-length [min-length 2])
  (distinct-strings
   (for/list ([tok (in-list (scan-words text))]
              #:when (>= (string-length (cadddr tok)) min-length))
     (cadddr tok))))

;;; ================= require spec → 引入的绑定名 =================
;;;
;;; 与 racket-langserver(drcomplete) 的 required/walk 同构：不是把 spec 拆成模块路径，
;;; 而是按 spec 结构算出**最终绑定名**（已套用 only/except/prefix/rename）。
;;; 于是 `(prefix-in l: racket/list)` 得到 `l:first`，`(only-in racket/list first)`
;;; 只得到 `first`，`(require "local.rkt")` 得到本地文件的导出。
;;; 对任意编辑中的文本是全函数：非法的 spec 一律 '()。

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

;; 在已有池里按前缀过滤（按长度升序，短的在前；同长按字典序） + 截断。
;; **排除与正在输入的词完全相同的候选**（已输入完整的 define 不再列出来）。
(define (shorter? a b)
  (or (< (string-length a) (string-length b))
      (and (= (string-length a) (string-length b)) (string<? a b))))

(define (filter-pool pool prefix #:limit [limit 500])
  (define matches
    (sort (for/list ([s (in-list pool)]
                     #:when (and (string-prefix? s prefix)
                                 (not (string=? s prefix))))
            s)
          shorter?))
  (if (> (length matches) limit) (take matches limit) matches))
