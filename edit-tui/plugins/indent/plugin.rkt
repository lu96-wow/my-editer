#lang racket

;;; edit-tui/plugins/indent/plugin.rkt —— Enter 换行缩进
;;;
;;; 对齐旧实现：使用 lang/racket 的 racket-indent-for-newline。
;;; 非 Racket 文本只插入普通换行。

(require "../../editor/api.rkt"
         (only-in "../../lang/racket/api.rkt"
                  racket-indent-for-newline))

(provide indent-plugin)

(define (before-insert ctx ps)
  (define text (edit-context-text ctx))
  (cond
    [(not (equal? text "\n")) (values ctx ps '() #t)]
    [else
     (define ed (edit-context-editor ctx))
     (define state (edit-context-state ctx))
     (define vid (edit-context-view-id ctx))
     (define did (editor-view-doc-id ed vid))
     (define whole (or (editor-view-text ed vid) ""))
     (cond
       [(not (eq? (state-doc-mode state did) 'racket))
        (values ctx ps '() #t)]
       [else
        (define pt (edit-context-point ctx))
        (define indent
          (racket-indent-for-newline whole
                                     (point-line pt)
                                     (point-column pt)))
        (values (struct-copy edit-context ctx
                             [text (string-append "\n" indent)])
                ps '() #t)])]))

(define indent-plugin
  (make-plugin
   #:id 'indent
   #:state #t
   #:hooks
   (list
    (make-hook #:owner 'indent
               #:id 'newline-indent
               #:operation 'insert
               #:phase 'transform
               #:priority 20
               #:fn before-insert))))
