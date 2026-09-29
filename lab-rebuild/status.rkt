#lang racket

;;; status.rkt —— 状态栏：只读文档，无输入
;;;
;;; 壳在每帧渲染前把它投影一次（焦点视图的 L/C + 文件名）。它不接收任何输入，
;;; 也不被任何文档耦合。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "app.rkt")

(provide status-project!)

(define (status-project! a)
  (define ed (app-editor a))
  (define vid (app-focus a))
  (define txt
    (cond
      [(not vid) ""]
      [(= vid (app-tree-vid a)) "  文件树"]
      [else
       (define did (editor-view-document-id ed vid))
       (define path (app-path a did))
       (format "  L~a C~a   ~a"
               (editor-view-point-line ed vid)
               (editor-view-point-col ed vid)
               (if path (path->string (file-name-from-path path))
                   (editor-view-document-name ed vid)))]))
  (define doc (document-highlight-fill (document-open txt) 0 0 0 (string-length txt) 'status))
  (struct-copy app a [editor (editor-view-assign (app-editor a) (app-status-vid a) doc)]))
