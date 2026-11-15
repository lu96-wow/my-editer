#lang racket

;;; edit-tui/plugins/indent/plugin.rkt —— Enter 换行行对齐
;;;
;;; Racket 复制当前行前导空白；C 在此基础上遇到上一行 { 时加一级。
;;; 其它文本只插入普通换行。

(require "../../editor/api.rkt"
         (only-in "../../lang/racket/api.rkt"
                  racket-indent-for-newline)
         (only-in "../../lang/c/api.rkt"
                  c-indent-for-newline))

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
     (define mode (state-doc-mode state did))
     (define pt (edit-context-point ctx))
     (define indent
       (case mode
         [(racket)
          (racket-indent-for-newline whole
                                     (point-line pt)
                                     (point-column pt))]
         [(c)
          (c-indent-for-newline whole
                                (point-line pt)
                                (point-column pt))]
         [else #f]))
     (cond
       [(not indent) (values ctx ps '() #t)]
       [else
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
