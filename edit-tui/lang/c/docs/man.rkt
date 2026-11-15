#lang racket

;;; edit-tui/lang/c/docs/man.rkt —— 调用系统 man 取 C / POSIX 文档
;;;
;;; 只使用外部 `man` 命令；不存在或没有对应页面时返回 #f。
;;; 结果按 name/section 缓存。输出通过 `-P cat` 取纯文本，去掉 backspace 过印。
;;; 可用 EDIT_MAN 指定 man 可执行文件。
;;;
;;; 只查 C / POSIX / Linux 常见节（3 / 2 / 3p / 7）。
;;; 不查 section 1：`man printf` 是 shell 命令，不是 C 的 printf(3)。

(require racket/list
         racket/port
         racket/string
         racket/system)

(provide (struct-out man-page)
         man-page-result
         man-page-text
         man-page-lines
         man-available?)

(struct man-page (content section) #:transparent)

(define (resolve-man)
  (define configured (getenv "EDIT_MAN"))
  (and configured
       (or (find-executable-path configured)
           (and (file-exists? configured) configured)
           #f)))

;; Termux 的 man 在 $PREFIX/bin；正常 PATH 下 find-executable-path 也能找到，
;; 这里作为 PATH 被裁剪时的兜底。
(define (termux-man)
  (define p (getenv "PREFIX"))
  (and p (find-executable-path (build-path p "bin" "man"))))

(define man-exe
  (or (resolve-man)
      (find-executable-path "man")
      (termux-man)
      (find-executable-path "/usr/bin/man")
      (find-executable-path "/bin/man")
      (find-executable-path "/usr/local/bin/man")))

(define man-cache (make-hash))
(define man-lock (make-semaphore 1))

(define (man-available?) (and man-exe #t))

(define (strip-backspaces s)
  (let loop ([cs (string->list s)] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [(char=? (car cs) #\backspace)
       (loop (cdr cs) (if (pair? acc) (cdr acc) acc))]
      [else (loop (cdr cs) (cons (car cs) acc))])))

(define (clean-man-text s)
  (define no-cr (string-replace s "\r" ""))
  (strip-backspaces no-cr))

(define (looks-like-missing? text)
  (or (regexp-match? #rx"No manual entry" text)
      (regexp-match? #rx"no manual entry" text)
      ;; 只匹配 man 的错误句式；不要用“没有.*手册页”，中文页面正文里
      ;; 可能同时出现“没有”和“手册页”，那会误杀。
      (regexp-match? #rx"没有关于.*手册页" text)
      (regexp-match? #rx"没有.*节.*手册页条目" text)))

(define (man-locale)
  ;; 例如 EDIT_C_MAN_LOCALE=zh_CN 强制中文页；不设则跟随进程 LANG/LC_ALL。
  (let ([v (or (getenv "EDIT_C_MAN_LOCALE")
               (getenv "EDIT_MAN_LOCALE"))])
    (and (string? v) (not (string=? v "")) v)))

(define (run-command args)
  (and man-exe
       (with-handlers ([exn:fail? (λ (_e) #f)])
         (define locale (man-locale))
         (define args*
           (if locale (append (list "-L" locale) args) args))
         (define-values (proc out in err)
           (apply subprocess #f #f #f man-exe args*))
         (close-output-port in)
         (define text (port->string out))
         (define _err (port->string err))
         (subprocess-wait proc)
         (and (zero? (subprocess-status proc))
              (non-empty-string? (string-trim text))
              (not (looks-like-missing? text))
              text))))

;; 先试 man-db 的 -P cat，再试 GNU --pager=cat，兼容少数实现。
(define (shell-page? text)
  ;; 防 fallback：请求 3p / 3 / 2 / 7 时，如果 man 实际给了 section 1
  ;; 的 shell 命令页，直接拒绝。C 文档永远不出现 printf(1)。
  (define first-line (car (string-split text "\n" #:trim? #f)))
  (regexp-match? #rx"\\(1[a-z]*\\)" first-line))

(define (run-man section name)
  (define sec (format "~a" section))
  (define text
    (or (run-command (list "-P" "cat" sec name))
        (run-command (list "--pager=cat" sec name))))
  (and text (not (shell-page? text)) text))

(define (drop-trailing-blank lines)
  (reverse
   (let loop ([ls (reverse lines)])
     (cond
       [(null? ls) '()]
       [(string=? (string-trim (car ls)) "") (loop (cdr ls))]
       [else ls]))))

(define (sections-for section)
  (remove-duplicates
   (append (if section (list (format "~a" section)) '())
           '("3" "2" "3p" "7"))))

(define (clean-page text section)
  (man-page
   (let* ([clean (clean-man-text text)]
          [lines (string-split clean "\n" #:trim? #f)]
          [lines* (drop-trailing-blank lines)])
     (string-join lines* "\n"))
   section))

;; → man-page | #f
(define (man-page-result name #:section [section #f])
  (cond
    [(not (string? name)) #f]
    [else
     (call-with-semaphore
      man-lock
      (λ ()
        (define key (list section name (man-locale)))
        (cond
          [(hash-has-key? man-cache key) (hash-ref man-cache key)]
          [else
           (define sections (sections-for section))
           (define found
             (for/or ([s (in-list sections)])
               (define text (run-man s name))
               (and text (clean-page text s))))
           ;; 只缓存命中。不要把 #f 永久缓存：用户可能刚安装 manpages-zh /
           ;; manpages-dev，下一次 M-d 应该能立即看到新页面。
           (when found (hash-set! man-cache key found))
           found])))]))


(define (man-page-text name #:section [section #f])
  (define page (man-page-result name #:section section))
  (and page (man-page-content page)))

(define (man-page-lines name #:section [section #f])
  (define text (man-page-text name #:section section))
  (and text (string-split text "\n" #:trim? #f)))
