#lang racket

;;; edit4/view/status.rkt —— 状态栏面板（纯投影）
;;;
;;; 读 World；不写引擎。写回统一由 view/panel.rkt 的 commit-panels! 做。
;;; 优先级：正在输入的多键命令序列 > 焦点文档的 name(相对路径) + 脏 + 行列。

(provide status-content)

(require racket/string
         "../core/world.rkt"
         "../content/model.rkt"
         "../content/adapter.rkt"
         "../content/tree.rkt")

(define (window-label c w id)
  (define fv (and id (content-vid-of c id)))
  (cond
    [(not fv) "(空窗口)"]
    [else
     (define ed (content-ed c))
     (define did (view-did ed fv))
     (define m (content-doc-meta c did))
     (define path (doc-path m))
     (if path (tree-relative-path w path) (view-document-name ed fv))]))

(define (status-line c w)
  (define fv (and (world-focus w) (content-vid-of c (world-focus w))))
  (cond
    [(not fv) (values "" '())]
    [else
     (define ed (content-ed c))
     (define did (view-did ed fv))
     (define dirty (if (doc-dirty? c did) " *" ""))
     (values (format " ~a~a   ~a:~a" (window-label c w (world-focus w)) dirty
                     (add1 (view-line ed fv)) (add1 (view-col ed fv)))
             (list (cons 0 'status-bar)))]))

(define (status-content w v)
  (define c (world-content w))
  (define ks (world-keys w))
  (cond
    [(pair? ks) (values (string-append " " (string-join ks " ")) (list (cons 0 'status-bar)))]
    [(content-placing c)
     (values (format " 选择目标窗口: ~a   Tab / M-n 切换   Enter 替换   Esc 取消"
                     (window-label c w (world-focus w)))
             (list (cons 0 'status-bar)))]
    [(content-swap c)
     (values (format " 互换视图: ~a → ~a   Tab / M-n 切换   c / Enter 确认   Esc 取消"
                     (window-label c w (swap-src (content-swap c)))
                     (window-label c w (world-focus w)))
             (list (cons 0 'status-bar)))]
    [else (status-line c w)]))
