#lang racket

;;; resources 显示路径：workspace root 内相对，root 外绝对。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt")

(define root (make-temporary-directory))
(define outside (make-temporary-directory))
(define inside (build-path root "a.rkt"))
(define nested (build-path root "sub" "b.rkt"))
(define outside-file (build-path outside "c.rkt"))
(void (make-directory (build-path root "sub")))
(display-to-file "a" inside #:exists 'replace)
(display-to-file "b" nested #:exists 'replace)
(display-to-file "c" outside-file #:exists 'replace)

(define root* (resource-normalize-path root))
(check-equal? (resource-display-path root* root*) ".")
(check-equal? (resource-display-path root* inside) "a.rkt")
(check-equal? (resource-display-path root* nested) (path->string (build-path "sub" "b.rkt")))
(check-equal? (resource-display-path root* outside-file)
              (resource-normalize-path outside-file))
(check-equal? (resource-display-path #f inside) (resource-normalize-path inside))

(delete-directory/files root)
(delete-directory/files outside)
(displayln "edit-tui/test/resource-path.rkt: ok")
