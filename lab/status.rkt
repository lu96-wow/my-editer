#lang racket

;;; ============================================================================
;;; status.rkt —— 状态栏组件：只读投影，无输入
;;; ============================================================================
;;;
;;; 状态栏是一个**没有输入的 pane**（pane 的 input / pointer = #f）：
;;;   · 它的 sync 每帧把「编辑格正在编辑的文档」的 L/C + 文件名投影成一行；
;;;   · 它只读 ctx，不反向影响任何东西。
;;;
;;; 投影内容不以「焦点在哪个 pane」为准，而是**编辑格 pane**，于是焦点在树上时
;;; 也不会浪费一行写"文件树"之类的标签。
;;;
;;; 退出问答时优先显示问题（y/n）。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "state.rkt")

(provide status-sync)

(define (status-sync ctx st)
  (define txt
    (cond
      [(ctx-quit-ask ctx) (ctx-quit-message ctx)]
      [else
       (define ed (ctx-editor ctx))
       (define vid (ctx-editor-vid ctx))
       (define did (editor-view-document-id ed vid))
       (define path (for/first ([(p d) (in-hash (ctx-opened ctx))] #:when (= d did)) p))
       (define name (if path (path->string (file-name-from-path path))
                        (editor-document-name ed did)))
       (format "  L~a C~a   ~a"
               (editor-view-point-line ed vid)
               (editor-view-point-col ed vid)
               name)]))
  ;; 整行一个 'status face（配色由后端决定）。
  (define doc (document-highlight-fill (document-open txt) 0 0 0 (string-length txt) 'status))
  (values doc st #f))
