#lang racket

;;; require 相关补全：
;;;   · (require "dep") 的绑定补全读取已打开 buffer 的 provide
;;;   · (require "de     的模块路径补全优先使用打开 buffer，再落磁盘

(require rackunit
         racket/file
         racket/path
         racket/string
         "../compat/lang/racket/api.rkt")

(define root (make-temporary-directory))
(define main-path (build-path root "main.rkt"))
(define dep-path (build-path root "dep.rkt"))
(display-to-file "#lang racket\n(provide disk-name)\n" dep-path #:exists 'replace)

(define dep-key (path->string (simplify-path dep-path)))
(define open
  (hash dep-key "#lang racket\n(provide buffer-name)\n(define x 1)\n"))

;;; ════════════════ require 绑定：buffer 优先 ════════════════

(define main-text (string-append "(require \"dep\")\n(define y bu"))
(define cands
  (completion-at (path->string main-path)
                 main-text
                 1
                 (string-length "(define y bu")
                 #:open open))
(check-true (and (member "buffer-name" cands) #t))
(check-false (member "disk-name" cands))

;;; ════════════════ require 字符串：路径补全 ════════════════

(define req-text "(require \"de")
(define req-col (string-length req-text))

;; 打开的 dep.rkt 命中。
(define path-cands
  (completion-at (path->string main-path) req-text 0 req-col #:open open))
(check-true (and (member "dep" path-cands) #t))

;; 没有打开的 buffer 时落磁盘。
(define disk-cands
  (completion-at (path->string main-path) req-text 0 req-col #:open (hash)))
(check-true (and (member "dep" disk-cands) #t))

;; 有打开的 buffer 命中时，不再扫磁盘。
(define dep2-path (build-path root "dep2.rkt"))
(display-to-file "#lang racket\n(provide dep2)\n" dep2-path #:exists 'replace)
(define open2
  (hash (path->string (simplify-path dep2-path)) "#lang racket\n(provide dep2)\n"))
(define open-hit-cands
  (completion-at (path->string main-path) req-text 0 req-col #:open open2))
(check-true (and (member "dep2" open-hit-cands) #t))
(check-false (member "dep" open-hit-cands))

(delete-directory/files root)
(displayln "edit-tui/test/require-completion.rkt: ok")
