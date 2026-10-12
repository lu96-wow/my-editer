#lang racket

;;; edit4/view/tree.rkt —— 文件树面板（纯投影）
;;;
;;; 只把 content/tree.rkt 的行结构渲染成文本 + faces；不读目录、不写引擎。

(provide tree-content)

(require racket/list
         "../core/world.rkt"
         "../content/model.rkt"
         "../content/tree.rkt")

(define (tree-content w v)
  (define c (world-content w))
  (define ts (and c (content-tree c)))
  (cond
    [(not ts) (values "" '())]
    [else
     (define rows (tree-rows ts))
     (define lines
       (for/list ([r (in-list rows)])
         (define nm (list-ref r 1))
         (string-append (make-string (* 2 (list-ref r 3)) #\space)
                        (if (list-ref r 2) (string-append nm "/") nm))))
     (values (string-join lines "\n")
             (for/list ([r (in-list rows)] [i (in-naturals)])
               (cons i (if (list-ref r 2) 'tree-dir 'tree-file))))]))
