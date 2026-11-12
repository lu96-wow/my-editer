#lang racket

(require racket/string)

;;; edit-tui/plugins/docs/model.rkt —— docs 面板状态（纯）

(provide (struct-out docs-state)
         empty-docs-state
         docs-faces)

(struct docs-state
  (view
   panel-id
   lines
   faces
   request-id
   name)
  #:transparent)

(define (empty-docs-state view panel-id)
  (docs-state view panel-id
              (list "No docs yet")
              (list 'docs-dim)
              #f
              #f))

(define (docs-faces lines)
  (for/list ([line (in-list lines)] [i (in-naturals)])
    (cond
      [(zero? i) 'docs-title]
      [(or (string-prefix? line "──") (string=? line "No docs yet")) 'docs-dim]
      [else 'docs-body])))
