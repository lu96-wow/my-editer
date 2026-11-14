#lang racket

;;; edit-tui/lang/racket/parse/local-docs.rkt —— 打开的本地文档里的定义（纯）
;;;
;;; 与标准库文档（setup/xref + blueboxes，走 worker / 长命缓存）**分开**：
;;; 这里只扫**当前缓冲区文本**的顶层定义，给某个名字一段源码摘要。
;;; 缓存不在这里（按文档版本）——本文件保持纯函数，便于测试。
;;;
;;; 有 analysis entries 时按 form-entry 的原始行范围截取源码，保留换行 / 缩进；
;;; 只有 entries 不可用时才退回 datum 的单行摘要。

(provide local-defs local-def local-defs-of-forms local-def-of-forms
         local-defs-of-entries local-def-of-entries)

(require racket/list racket/string
         "source.rkt"
         "analysis.rkt")

(define snippet-width 72)

;; datum 兜底：读回 datum 后 ~s 会压成一行；过长截断。
(define (form->string f)
  (define s (with-handlers ([exn:fail? (lambda (_) "#<...>")])
              (format "~s" f)))
  (define one (car (string-split s "\n")))
  (if (> (string-length one) snippet-width)
      (string-append (substring one 0 snippet-width) " …")
      one))

;; 顶层定义表单 -> 定义名列表。
(define (def-names f)
  (cond
    [(not (pair? f)) '()]
    [else
     (case (car f)
       [(define define-syntax define-syntax-rule)
        (define t (and (pair? (cdr f)) (cadr f)))
        (cond
          [(symbol? t) (list t)]
          [(and (pair? t) (symbol? (car t))) (list (car t))]
          [else '()])]
       [(define-values)
        (define t (and (pair? (cdr f)) (cadr f)))
        (cond
          [(and (pair? t) (andmap symbol? t)) t]
          [else '()])]
       [(struct struct* define-struct)
        (define t (and (pair? (cdr f)) (cadr f)))
        (if (symbol? t) (list t) '())]
       [else '()])]))

(define (names->snippets names snippet)
  (for/list ([n (in-list names)]) (cons n snippet)))

;; form -> (listof (cons name snippet))，datum 兜底。
(define (def-snippets f)
  (names->snippets (def-names f) (form->string f)))

;; 已读好的 forms -> (hash 名 -> 摘要)。
(define (local-defs-of-forms forms)
  (define snippets (append* (for/list ([f (in-list forms)]) (def-snippets f))))
  (for/hash ([p (in-list snippets)]) (values (car p) (cdr p))))

;;; ════════════════ 原始源码切片 ════════════════

(define (entry-snippet text linesv e)
  (define n (vector-length linesv))
  (define start (max 0 (min (form-entry-start-line e) n)))
  (define end (max start (min (form-entry-end-line e) n)))
  (string-join
   (for/list ([i (in-range start end)])
     (vector-ref linesv i))
   "\n"))

(define (entry->snippets text linesv e)
  (names->snippets (def-names (form-entry-form e))
                   (entry-snippet text linesv e)))

;; text + analysis entries -> (hash 名 -> 原始源码片段)。
(define (local-defs-of-entries text entries)
  (define linesv
    (list->vector (string-split text "\n" #:trim? #f)))
  (define snippets
    (append* (for/list ([e (in-list entries)])
               (entry->snippets text linesv e))))
  (for/hash ([p (in-list snippets)]) (values (car p) (cdr p))))

(define (local-def-of-entries text entries name)
  (hash-ref (local-defs-of-entries text entries) name #f))

;; 源码文本 -> (hash 名 -> 摘要)。
(define (local-defs text)
  (define a (with-handlers ([exn:fail? (lambda (_) #f)])
              (analyze-source #f text)))
  (cond
    [(not a) (hash)]
    [else
     (define entries (module-analysis-entries a))
     (if entries
         (local-defs-of-entries text entries)
         (local-defs-of-forms (module-analysis-forms a)))]))

(define (local-def-of-forms forms name)
  (hash-ref (local-defs-of-forms forms) name #f))

;; 直接按名字取（找不到 → #f）。
(define (local-def text name)
  (hash-ref (local-defs text) name #f))
