#lang racket

;;; edit-tui-rebuild/filetree/scan.rkt —— 读目录（唯一 IO 点）

(provide dir-entries)

(require racket/path
         racket/list
         racket/string)

(define (entry-kind path)
  (cond
    [(and (directory-exists? path) (not (link-exists? path))) 'dir]
    [(file-exists? path) 'file]
    [else #f]))

(define (name<? a b)
  (string<? (string-downcase (path->string (file-name-from-path a)))
            (string-downcase (path->string (file-name-from-path b)))))

(define (dir-entries path)
  (with-handlers ([exn:fail? (λ (_) '())])
    (define es
      (for/list ([n (in-list (directory-list path))])
        (define child (build-path path n))
        (define k (entry-kind child))
        (and k (cons k child))))
    (sort (filter values es)
          (λ (a b)
            (define ka (car a))
            (define kb (car b))
            (cond [(and (eq? ka 'dir) (eq? kb 'file)) #t]
                  [(and (eq? ka 'file) (eq? kb 'dir)) #f]
                  [else (name<? (cdr a) (cdr b))])))))
