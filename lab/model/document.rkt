#lang racket

;;; lab/model/document.rkt —— 内容单元的门面（按 did）
;;;
;;; core 已经持有文本 / 属性 / 撤销 / 名字；这里只补 core 没有的：
;;; 文件路径 + dirty（保存点）。dirty 判定用 **document 值身份**（不可变 + 结构共享 ⇒ O(1)）。

(require
 "session.rkt"
 "../../core/editor.rkt"
 "../../core/text/document.rkt")

(provide
 document-text
 document-name
 document-path
 document-saved-doc
 document-dirty?
 document-set-path
 document-mark-saved
 document-commands
 document-set-commands!
 document-can-undo?
 document-can-redo?)

(define (entry s did) (editor-document-entry (session-editor s) did))

(define (document-text s did)
  (document->string (document-entry-document (entry s did))))

(define (document-name s did)
  (document-entry-name (entry s did)))

(define (document-path s did)
  (doc-meta-path (hash-ref (session-docs s) did)))

(define (document-saved-doc s did)
  (doc-meta-saved-doc (hash-ref (session-docs s) did)))

;; 当前 document 值与保存点不是同一个对象 ⇒ 有改动。
(define (document-dirty? s did)
  (define m (hash-ref (session-docs s) did))
  (not (eq? (doc-meta-saved-doc m) (document-entry-document (entry s did)))))

(define (document-set-path s did path)
  (define m (hash-ref (session-docs s) did))
  (struct-copy session s
    [docs (hash-set (session-docs s) did
                    (doc-meta path (doc-meta-saved-doc m) (doc-meta-commands m)))]))

;; 每文档命令表（覆盖默认表）；#f = 只用默认表。
(define (document-commands s did)
  (doc-meta-commands (hash-ref (session-docs s) did)))

(define (document-set-commands! s did cmds)
  (define m (hash-ref (session-docs s) did))
  (struct-copy session s
    [docs (hash-set (session-docs s) did
                    (doc-meta (doc-meta-path m) (doc-meta-saved-doc m) cmds))]))

;; 保存后调用：把当前 document 值记为保存点。
(define (document-mark-saved s did)
  (define m (hash-ref (session-docs s) did))
  (struct-copy session s
    [docs (hash-set (session-docs s) did
                    (doc-meta (doc-meta-path m)
                              (document-entry-document (entry s did))
                              (doc-meta-commands m)))]))

(define (document-can-undo? s did)
  (history-can-undo? (editor-document-history (session-editor s) did)))

(define (document-can-redo? s did)
  (history-can-redo? (editor-document-history (session-editor s) did)))
