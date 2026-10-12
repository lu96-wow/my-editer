#lang racket

;;; edit4/view/status.rkt —— 状态栏面板（纯投影）
;;;
;;; 读 World；不写引擎。写回统一由 view/panel.rkt 的 commit-panels! 做。

(provide status-content)

(require racket/path
         "../core/world.rkt"
         "../content/model.rkt"
         "../content/adapter.rkt")

(define (status-content w v)
  (define c (world-content w))
  (define fv (and (world-focus w) (content-vid-of c (world-focus w))))
  (define ed (content-ed c))
  (cond
    [(not fv) (values "" '())]
    [else
     (define did (view-did ed fv))
     (define m (content-doc-meta c did))
     (define path (doc-path m))
     (define name (if path (path->string (file-name-from-path path)) (view-document-name ed fv)))
     (define dirty (if (doc-dirty? c did) " *" ""))
     (values (format " ~a~a   ~a:~a" name dirty (add1 (view-line ed fv)) (add1 (view-col ed fv)))
             (list (cons 0 'status-bar)))]))
