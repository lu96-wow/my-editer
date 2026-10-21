#lang racket

;;; edit-tui-rebuild/filetree/lines.rkt —— 纯投影：path/expanded -> 行

(require racket/path
         "../core/skeleton.rkt"
         "model.rkt")

(provide filetree-lines
         filetree-line-at
         default-hidden-entry?)

(define (indent depth) (make-string (* 2 depth) #\space))

(define (entry-name path)
  (path->string (file-name-from-path path)))

;; 默认隐藏规则：文件名以 . 开头。
(define (default-hidden-entry? path)
  (define name (entry-name path))
  (and (positive? (string-length name))
       (char=? #\. (string-ref name 0))))

;; entry-lister : string -> (listof (cons ('dir|'file) path))
;; opened       : hash path -> #t
;; hidden-entry? : path -> boolean；可组合的额外过滤规则。
(define (filetree-lines root expanded opened entry-lister
                        #:show-hidden? [show-hidden? #f]
                        #:hidden-entry? [hidden-entry? default-hidden-entry?])
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
             (append* (for/list ([e (in-list (entry-lister pn))]
                                 #:unless (and (not show-hidden?)
                                               (hidden-entry? (cdr e))))
                        (walk (cdr e) (add1 depth) (car e))))
             '()))
       (cons line children))
     (walk root-norm 0 'dir)]))

(define (filetree-line-at rows line)
  (and (exact-nonnegative-integer? line)
       (< line (length rows))
       (list-ref rows line)))
