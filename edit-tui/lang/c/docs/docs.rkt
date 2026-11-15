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
         racket/path
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

(define (header-page-name header)
  (and header
       (let ([name (file-name-from-path (string->path header))])
         (and name
              (let ([s (path->string name)])
                (if (string-suffix? s ".h")
                    (substring s 0 (- (string-length s) 2))
                    s))))))

(define (han-char? c)
  (<= #x4e00 (char->integer c) #x9fff))

(define (has-han? s)
  (for/or ([c (in-string s)]) (han-char? c)))

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

(define (current-locale)
  (or (getenv "EDIT_C_MAN_LOCALE")
      (getenv "LC_ALL")
      (getenv "LC_MESSAGES")
      (getenv "LANG")
      ""))

(define (chinese-locale?)
  (define loc (string-downcase (current-locale)))
  (or (string-prefix? loc "zh")
      (string-contains? loc "zh_cn")
      (string-contains? loc "zh_tw")))

(define (c-docs-lines name #:text [text #f])
  (define local (and text (c-local-def text name)))
  (define e (c-lib-entry-for name))
  (define page
    (man-page-result name #:section (and e (c-lib-entry-section e))))
  (define exact-chinese? (and page (has-han? (man-page-content page))))
  ;; 精确页缺失，或精确页是英文但当前是中文环境时：
  ;; 尝试相关头文件汇总页（例如 printf -> 中文 stdio(3)）。
  ;; 只有相关页确实是中文才用，避免把英文汇总页重复一遍。
  (define related
    (and e
         (not exact-chinese?)
         (chinese-locale?)
         (let* ([h (c-lib-entry-header e)]
                [related-name (header-page-name h)])
           (and related-name
                (let ([p (man-page-result related-name
                                          #:section (c-lib-entry-section e))])
                  (and p (has-han? (man-page-content p)) p))))))
  (define related-name
    (and related e (header-page-name (c-lib-entry-header e))))
  (define man-section (and page (man-page-section page)))
  (define man-text (and page (man-page-content page)))
  (define exact-label
    (cond
      [exact-chinese? (format "── man ~a（中文）──" man-section)]
      [man-section (format "── man ~a（English）──" man-section)]
      [else "── man ──"]))
  (define related-label
    (and related
         (format "── man ~a ~a（相关头文件页，中文）──"
                 (man-page-section related) related-name)))
  (define declaration
    (if e (cons "── 声明 ──" (entry-lines e)) '()))
  (define local-lines
    (if local
        (cons "── 本地定义 ──" (string-split local "\n" #:trim? #f))
        '()))
  (define no-c-man
    (if (or page related)
        '()
        (list "── man ──"
              (format "没有找到 ~a 的 C libc 手册页（section 3/2/3p/7）。" name)
              "安装 man-db + man-pages / manpages-dev 后重试。")))
  (cond
    [exact-chinese?
     (append (list (format "~a" name))
             local-lines
             (cons exact-label (string-split man-text "\n" #:trim? #f)))]
    [(and page related)
     (append (list (format "~a" name))
             local-lines
             declaration
             (list related-label
                   (format "（没有 ~a 的独立中文页；以下是相关头文件的中文说明）" name))
             (string-split (man-page-content related) "\n" #:trim? #f)
             (list exact-label)
             (string-split man-text "\n" #:trim? #f))]
    [page
     (append (list (format "~a" name))
             local-lines
             (cons exact-label (string-split man-text "\n" #:trim? #f)))]
    [related
     (append (list (format "~a" name))
             local-lines
             declaration
             (list related-label
                   (format "（没有 ~a 的独立页；以下是相关头文件的中文说明）" name))
             (string-split (man-page-content related) "\n" #:trim? #f))]
    [e
     (append (list (format "~a" name))
             local-lines
             declaration
             no-c-man)]
    [else
     (append (list (format "~a" name))
             local-lines
             (list "── 文档 ──" "(no manual entry)")
             no-c-man)]))
