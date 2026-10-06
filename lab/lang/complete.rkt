#lang racket

;;; lab-rebuild/lang/complete.rkt —— 前缀 → 补全候选（纯）
;;;
;;; 候选来源（并集、去重、按前缀过滤、排序）：
;;;   1) 基础命名空间的名字（racket/base 等，覆盖内置）；
;;;   2) 候选模块（#lang 语言 + 各 require）的导出（module->exports）；
;;;   3) 文件里顶层定义的名字（lang/source 扫出来）。
;;;
;;; module->exports 不需要实例化模块，且按模块缓存，够快；本文件不认识 app / editor。
;;;
;;; 自动补全每个字符都会过滤一次：把「候选池」与「按前缀过滤」拆开，
;;; 一次补全会话只建一次池（见 core/actions/lang.rkt），之后只 filter-pool。

(provide completions completion-pool filter-pool module-exports)

(require racket/list racket/string)

;;; ================= 缓存 =================

(define base-syms (delay (namespace-mapped-symbols (make-base-namespace))))
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

;; 候选池：基础命名空间 + 各候选模块导出 + 本地定义（去重、未排序）。
;; 「建池」会调 module->exports / 读本地定义，较贵；一个补全会话只建一次。
(define (completion-pool #:modules [mods '()] #:locals [locals '()])
  (remove-duplicates
   (append (append* (for/list ([m (in-list mods)]) (module-exports m)))
           (map symbol->string (force base-syms))
           (map symbol->string locals))
   equal?))

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
                     #:limit [limit 500])
  (filter-pool (completion-pool #:modules mods #:locals locals) prefix #:limit limit))
