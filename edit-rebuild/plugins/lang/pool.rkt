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
         module-exports document-words)

(require racket/list
         racket/string
         "../../core/face/lex.rkt")

;;; ================= 缓存 =================

(define exports-cache (make-hash))       ; module-path -> (listof string)

;; 一个模块的导出名（值 + 语法，所有 phase），字符串形式。
(define (module-exports m)
  (hash-ref! exports-cache m
    (λ ()
      (with-handlers ([exn:fail? (λ (_) '())])
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
