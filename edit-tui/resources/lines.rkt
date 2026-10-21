#lang racket

;;; edit-tui/resources/lines.rkt —— resources -> 行（纯）

(require (only-in racket/list append*)
         "../core/skeleton.rkt"
         "model.rkt")

(provide resource-panel-lines
         resource-panel-line-at)

(define (resource-label store r)
  (define id (resource-id r))
  (define path (resource-path store id))
  (if path
      (resource-display-path store path)
      (resource-name r)))

;; buffer 行在前，它的 views 缩进挂在后面。
(define (resource-panel-lines store)
  (append*
   (for/list ([r (in-list (resource-list store))])
     (define id (resource-id r))
     (define dirty? (resource-dirty? store id))
     (define label (string-append (resource-label store r)
                                  (if dirty? " *" "")))
     (cons (resource-line 'buffer id #f label
                          (if dirty? 'resource-pending 'resource-document))
           (for/list ([vid (in-list (resource-view-ids store id))])
             (resource-line 'view id vid
                            (format "  view ~a" vid)
                            'resource-view))))))

(define (resource-panel-line-at rows line)
  (and (exact-nonnegative-integer? line)
       (< line (length rows))
       (list-ref rows line)))
