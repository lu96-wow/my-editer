#lang racket

;;; ============================================================================
;;; status.rkt —— 状态栏：只读文档，无输入
;;; ============================================================================
;;;
;;; 状态栏是一个**没有输入的 pane**：
;;;   · 它的 pane input / pointer 都是 #f（壳不会把输入交给它）；
;;;   · 壳在每帧渲染前调 status-project! 把它投影一次；
;;;   · 它只读 app，不反向影响任何东西。
;;;
;;; 投影内容 = **编辑格正在编辑的文档**的 L/C + 文件名（不是"焦点在哪个 pane"）。
;;; 这样焦点在树上的时候，状态栏也不会浪费一行去写"文件树"之类的标签 —— 它始终
;;; 显示你正在编辑的那个文件的定位信息。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "app.rkt")

(provide status-project!)

(define (status-project! a pid)
  (define ed (app-editor a))
  (define vid (app-pane-vid a (app-editor-pane a)))      ; 编辑格（不随焦点变）
  (define did (editor-view-document-id ed vid))
  (define path (app-path a did))
  (define name (if path (path->string (file-name-from-path path))
                   (editor-view-document-name ed did)))
  (define txt (format "  L~a C~a   ~a"
                      (editor-view-point-line ed vid)
                      (editor-view-point-col ed vid)
                      name))
  ;; 整行一个 'status face（配色由后端决定）。
  (define doc (document-highlight-fill (document-open txt) 0 0 0 (string-length txt) 'status))
  (struct-copy app a [editor (editor-view-assign (app-editor a) (app-pane-vid a pid) doc)]))
