#lang racket

;;; edit4/content/buffers.rkt —— 文档管理面板的行模型（纯）
;;;
;;; 每个「非面板」文档一行（▾/▸/空 标记由投影决定），其视图作为子行。
;;; 行结构 row = (list did vid label depth kind)，kind = 'doc | 'view。
;;; 选择行不另设游标：面板就是 document，view-line 即当前行。

(provide buffer-rows)

(require racket/list racket/path
         "../core/world.rkt"
         "model.rkt" "adapter.rkt" "tree.rkt")

(define (doc-label w did)
  (define c (world-content w))
  (define ed (content-ed c))
  (define m (content-doc-meta c did))
  (define p (and m (doc-path m)))
  (if p (tree-relative-path w p) (document-name ed did)))

(define (buffer-rows w)
  (define c (world-content w))
  (define ed (content-ed c))
  (define folded (content-fold c))
  (append*
   (for/list ([did (in-list (document-id-list ed))])
     (cond
       [(panel-doc-name? c (document-name ed did)) '()]
       [else
        (define vids (document-view-list ed did))
        (define doc-row (list did #f (doc-label w did) 0 'doc))
        (cond
          [(hash-has-key? folded did) (list doc-row)]
          [(null? vids) (list doc-row)]
          [else (cons doc-row
                      (for/list ([vid (in-list vids)])
                        (list did vid
                              (format "~a:~a" (add1 (view-line ed vid)) (add1 (view-col ed vid)))
                              1 'view)))])]))))
