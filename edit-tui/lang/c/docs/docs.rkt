#lang racket

;;; edit-tui/lang/c/docs/docs.rkt —— C 标识符文档
;;;
;;; 优先级：
;;;   1. 当前 buffer 里的本地声明 / 定义；
;;;   2. 内置 C / POSIX / Linux lib 索引的签名与摘要；
;;;   3. 系统 man 手册（有就显示完整页面）。
;;;
;;; 只返回字符串行；面板 / 颜色 / 异步由 docs 插件负责。

(require racket/list
         racket/string
         "../base/lex.rkt"
         "../data/lib.rkt"
         "man.rkt")

(provide c-local-def
         c-docs-lines)

(define (line-text lines i)
  (and (>= i 0) (< i (length lines)) (list-ref lines i)))

(define (leading-ws s)
  (let loop ([i 0])
    (if (and (< i (string-length s))
             (or (char=? (string-ref s i) #\space)
                 (char=? (string-ref s i) #\tab)))
        (loop (add1 i))
        (substring s 0 i))))

(define (next-non-ws tokens start)
  (for/first ([t (in-list tokens)]
              #:when (>= (c-token-start t) start)
              #:unless (eq? (c-token-kind t) 'whitespace))
    t))

(define (prev-non-ws tokens end)
  (for/last ([t (in-list tokens)]
             #:when (< (c-token-end t) end)
             #:unless (eq? (c-token-kind t) 'whitespace))
    t))

(define (word-at line t)
  (substring line (c-token-start t)
             (min (c-token-end t) (string-length line))))

;; 在 line 上找 name 后面紧跟 '(' 的位置。
(define (decl-candidate? line tokens name)
  (for/or ([t (in-list tokens)]
           #:when (and (memq (c-token-kind t) '(identifier keyword type))
                       (equal? (word-at line t) name)))
    (define next (next-non-ws tokens (c-token-end t)))
    (and next
         (eq? (c-token-kind next) 'punct)
         (< (c-token-start next) (string-length line))
         (char=? (string-ref line (c-token-start next)) #\())))

;; 同一行 name 前面是否有类型 token（int / struct / FILE / size_t ...）。
;; 还要求 name 的直接前一个非空白 token 是类型 / 标识符 / '*'，
;; 避免把 `return printf(...)` / `(int) printf(...)` 这类调用当成定义。
(define (decl-ish? line tokens name)
  (define name-start
    (for/first ([t (in-list tokens)]
                #:when (and (memq (c-token-kind t) '(identifier keyword type))
                            (equal? (word-at line t) name)))
      (c-token-start t)))
  (and name-start
       (let* ([prev (prev-non-ws tokens name-start)]
              [any-type?
               (for/or ([t (in-list tokens)])
                 (and (< (c-token-end t) name-start)
                      (eq? (c-token-kind t) 'type)))])
         (and any-type?
              (or (and prev (memq (c-token-kind prev) '(type identifier)))
                  (and prev
                       (eq? (c-token-kind prev) 'punct)
                       (< (c-token-start prev) (string-length line))
                       (char=? (string-ref line (c-token-start prev)) #\*)))))))

(define (snippet-from lines start)
  (define max-end (min (length lines) (+ start 4)))
  (define collected
    (for/list ([i (in-range start max-end)])
      (list-ref lines i)))
  (define trimmed
    (let loop ([ls collected] [acc '()])
      (cond
        [(null? ls) (reverse acc)]
        [else
         (define l (car ls))
         (define done?
           (or (string-contains? l ";")
               (string-contains? l "{")))
         (loop (if done? '() (cdr ls)) (cons l acc))])))
  (string-join trimmed "\n"))

;; text / name -> 本地声明片段 | #f
(define (c-local-def text name)
  (define lines (c-text-lines text))
  (define token-lines (c-tokenize text))
  (define candidates
    (for/list ([line (in-list lines)]
               [tokens (in-list token-lines)]
               [i (in-naturals)]
               #:when (and (not (null? tokens))
                           (decl-candidate? line tokens name)))
      (list (decl-ish? line tokens name) i)))
  ;; 只接受“前面有类型 / 存储类 / *”的候选，避免把调用点当成定义。
  (define chosen
    (for/first ([c (in-list candidates)] #:when (car c)) c))
  (and chosen (snippet-from lines (cadr chosen))))

(define (entry-lines e)
  (append
   (if (c-lib-entry-header e)
       (list (format "#include <~a>" (c-lib-entry-header e)))
       '())
   (if (c-lib-entry-signature e)
       (list (c-lib-entry-signature e))
       '())
   (if (c-lib-entry-summary e)
       (list (c-lib-entry-summary e))
       '())))

(define (c-docs-lines name #:text [text #f])
  (define local (and text (c-local-def text name)))
  (define e (c-lib-entry-for name))
  (define page
    (man-page-result name #:section (and e (c-lib-entry-section e))))
  (define man-section (and page (man-page-section page)))
  (define man-text (and page (man-page-content page)))
  (define man-label
    (if man-section
        (format "── man ~a ──" man-section)
        "── man ──"))
  (define no-c-man
    (if page
        '()
        (list "── man ──"
              (format "没有找到 ~a 的 C libc 手册页（section 3/2/3p/7）。" name)
              "安装 man-db + man-pages / manpages-dev 后重试。")))
  (define local-lines
    (if local
        (cons "── 本地定义 ──" (string-split local "\n" #:trim? #f))
        '()))
  (cond
    [page
     (append (list (format "~a" name))
             local-lines
             (cons man-label (string-split man-text "\n" #:trim? #f)))]
    [e
     (append (list (format "~a" name))
             local-lines
             (cons "── 声明 ──" (entry-lines e))
             no-c-man)]
    [else
     (append (list (format "~a" name))
             local-lines
             (list "── 文档 ──" "(no manual entry)")
             no-c-man)]))
