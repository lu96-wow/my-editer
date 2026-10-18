#lang racket

;;; layer  : plugins/lang
;;; effect : 无（纯值 / 仅在 worker 进程里做 IO）
;;;
;;; local-docs.rkt —— 当前文档里的顶层定义摘要（纯）

;;; edit-rebuild/plugins/lang/local-docs.rkt —— 打开的本地文档里的定义（纯）
;;;
;;; 与标准库文档（setup/xref + blueboxes，走 worker / 长命缓存）**分开**：
;;; 这里只扫**当前缓冲区文本**的顶层定义，给某个名字一行源码摘要。
;;; 缓存不在这里（按文档版本）——本文件保持纯函数，便于测试。

(provide local-defs local-def)

(require racket/list racket/string
         "source.rkt")

(define snippet-width 72)

;; 一个顶层表单 → 一行的源码摘要（读回 datum 后 ~s 会压成一行；过长截断）。
(define (form->string f)
  (define s (with-handlers ([exn:fail? (lambda (_) "#<...>")])
              (format "~s" f)))
  (define one (car (string-split s "\n")))
  (if (> (string-length one) snippet-width)
      (string-append (substring one 0 snippet-width) " …")
      one))

;; 顶层定义表单 → (listof (cons name snippet))。
(define (def-snippets f)
  (cond
    [(not (pair? f)) '()]
    [else
     (define snip (form->string f))
     (case (car f)
       [(define define-syntax define-syntax-rule)
        (define t (and (pair? (cdr f)) (cadr f)))
        (cond
          [(symbol? t) (list (cons t snip))]
          [(and (pair? t) (symbol? (car t))) (list (cons (car t) snip))]
          [else '()])]
       [(define-values)
        (define t (and (pair? (cdr f)) (cadr f)))
        (cond
          [(and (pair? t) (andmap symbol? t)) (for/list ([n (in-list t)]) (cons n snip))]
          [else '()])]
       [(struct struct* define-struct)
        (define t (and (pair? (cdr f)) (cadr f)))
        (if (symbol? t) (list (cons t snip)) '())]
       [else '()])]))

;; 源码文本 → (hash 名 -> 摘要)。
(define (local-defs text)
  (define-values (_lang forms) (module-context text))
  (define snippets (append* (for/list ([f (in-list forms)]) (def-snippets f))))
  (for/hash ([p (in-list snippets)]) (values (car p) (cdr p))))

;; 直接按名字取（找不到 → #f）。
(define (local-def text name)
  (hash-ref (local-defs text) name #f))
