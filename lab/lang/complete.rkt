#lang racket

;;; lab-rebuild/lang/complete.rkt —— 前缀 → 补全候选（纯）
;;;
;;; 候选来源（并集、去重、按前缀过滤、排序）：
;;;   1) 基础命名空间的名字（racket/base 等，覆盖内置）；
;;;   2) 候选模块（#lang 语言 + 各 require）的导出（module->exports）；
;;;   3) 文件里顶层定义的名字（lang/source 扫出来）。
;;;
;;; module->exports 不需要实例化模块，且按模块缓存，够快；本文件不认识 app / editor。

(provide completions module-exports)

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

;; prefix : string（光标左侧的词）。返回排序后的候选（最多 limit 个）。
(define (completions prefix
                     #:modules [mods '()]
                     #:locals [locals '()]
                     #:limit [limit 500])
  (define pool
    (remove-duplicates
     (append (append* (for/list ([m (in-list mods)]) (module-exports m)))
             (map symbol->string (force base-syms))
             (map symbol->string locals))
     equal?))
  (define matches
    (sort (for/list ([s (in-list pool)] #:when (string-prefix? s prefix)) s)
          string<?))
  (if (> (length matches) limit) (take matches limit) matches))
