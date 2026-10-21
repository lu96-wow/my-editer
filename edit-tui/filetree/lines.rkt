#lang racket

;;; edit-tui-rebuild/filetree/lines.rkt —— 纯投影：path/expanded -> 行

(require racket/path
         "../core/skeleton.rkt"
         "model.rkt")

(provide filetree-lines
         filetree-line-at)

(define (indent depth) (make-string (* 2 depth) #\space))

(define (entry-name path)
  (path->string (file-name-from-path path)))

;; entry-lister : string -> (listof (cons ('dir|'file) path))
;; opened       : hash path -> #t
(define (filetree-lines root expanded opened entry-lister)
  (cond
    [(or (not root) (string=? root "")) '()]
    [else
     (define root-norm (resource-normalize-path root))
     (define (walk path depth kind)
       (define pn (resource-normalize-path path))
       ;; 根显示绝对路径；子项显示文件名。
       (define label (if (zero? depth) root-norm (entry-name path)))
       (define face
         (cond [(zero? depth) 'filetree-root]
               [(eq? kind 'dir) 'filetree-dir]
               [(hash-has-key? opened pn) 'filetree-open]
               [else 'filetree-file]))
       (define line
         (filetree-line pn (if (zero? depth) 'root kind) depth
                        (string-append (indent depth) label)
                        face))
       (define children
         (if (and (eq? kind 'dir) (hash-has-key? expanded pn))
             (append* (for/list ([e (in-list (entry-lister pn))])
                        (walk (cdr e) (add1 depth) (car e))))
             '()))
       (cons line children))
     (walk root-norm 0 'dir)]))

(define (filetree-line-at rows line)
  (and (exact-nonnegative-integer? line)
       (< line (length rows))
       (list-ref rows line)))
