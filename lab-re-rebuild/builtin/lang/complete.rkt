#lang racket

;;; lab/builtin/lang/complete.rkt —— 前缀 → 补全候选（纯）
;;;
;;; 候选来源（并集、去重、按前缀过滤、排序）：
;;;   1) 候选模块（#lang 语言 + 各 require）的导出（module->exports）；
;;;   2) 文件里顶层定义的名字（lang/source 扫出来）；
;;;   3) 文件里出现过的词（lang/lex 扫出来；dabbrev 式）。
;;; 模块上下文由 `doc-job/view-modules` 给定（严格 = #lang + require；无则 racket/base）。
;;;
;;; 「出现过的词」用共享词法器 `lang/lex` 扫 —— 与高亮词色**同一套词法**（同一个原子），
;;; 因此不需要、也不应该去读高亮插件的私有状态表（那张表在特性内部、可能在 worker 里）。
;;;
;;; module->exports 不需要实例化模块，且按模块缓存，够快；本文件不认识 app / editor。
;;;
;;; 自动补全每个字符都会过滤一次：把「候选池」与「按前缀过滤」拆开，
;;; 一次补全会话只建一次池（见 complete.rkt），之后只 filter-pool。

(provide completions completion-pool filter-pool module-exports document-words)

(require racket/list racket/string
         "lex.rkt")

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

;;; ================= 补全 =================

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
;; 模块列表已含文件的语言基座（`view-modules`）；无 lang 无 require 时那边会默认
;; racket/base，所以这里不再无条件加基础命名空间。
;; 「建池」会调 module->exports / 读本地定义 / 扫全篇词，较贵；一个补全会话只建一次。
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

;; 在已有池里按前缀过滤（排序 + 截断）。每次按键只走这里，够快。
(define (filter-pool pool prefix #:limit [limit 500])
  (define matches
    (sort (for/list ([s (in-list pool)] #:when (string-prefix? s prefix)) s)
          string<?))
  (if (> (length matches) limit) (take matches limit) matches))

;; prefix : string（光标左侧的词）。返回排序后的候选（最多 limit 个）。
;; 一次性便捷入口：建池 + 过滤；分多次过滤时用 completion-pool / filter-pool。
(define (completions prefix
                     #:modules [mods '()]
                     #:locals [locals '()]
                     #:words [words '()]
                     #:limit [limit 500])
  (filter-pool (completion-pool #:modules mods #:locals locals #:words words) prefix #:limit limit))
