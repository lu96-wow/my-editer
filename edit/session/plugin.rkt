#lang racket

;;; edit/session/plugin.rkt —— document 插件绑定 / 写回（会话侧）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来。
;;; 写回：渲染前对绑了插件、且文档句柄变了的文档，重算 fills 并写 face 端口。
;;;   · 引擎每次编辑自动 rebase face 端口并产生新句柄 →「句柄变了」= 文本变了
;;;     （undo 同理），所以 lazy 判据就是句柄比较，不需要捕获 change。
;;;   · face 端口写回走 core.rkt 的通用原语 session-doc-face!；本层只认识插件协议。
;;;
;;; 内核（core.rkt）不认识 doc-plugin；插件协议只在 plugin/registry.rkt 与这里。

(require "value.rkt"
         "doc.rkt"
         "core.rkt"
         "../plugin/registry.rkt")

(provide session-doc-plugins session-doc-bind-plugins
         session-doc-applied session-doc-mark-applied
         session-doc-plugin-forget
         session-doc-plugins-apply)

;;; ---------- 绑定 / 缓存（纯） ----------

(define (session-doc-plugins s did) (hash-ref (session-plugin-bindings s) did '()))
(define (session-doc-bind-plugins s did ps)
  (struct-copy session s [plugin-bindings (hash-set (session-plugin-bindings s) did ps)]))

(define (session-doc-applied s did) (hash-ref (session-plugin-applied s) did #f))
(define (session-doc-mark-applied s did h)
  (struct-copy session s [plugin-applied (hash-set (session-plugin-applied s) did h)]))

;; 关文档时清掉该 did 的绑定与缓存。
(define (session-doc-plugin-forget s did)
  (struct-copy session s
    [plugin-bindings (hash-remove (session-plugin-bindings s) did)]
    [plugin-applied (hash-remove (session-plugin-applied s) did)]))

;;; ---------- 渲染前写回 ----------

(define (session-doc-plugins-apply s)
  (for/fold ([s s]) ([did (in-list (session-document-ids s))])
    (define path (session-file-path s did))
    (define ps (session-doc-plugins s did))
    (cond
      [(or (not path) (null? ps)) s]
      [else
       (define h (session-document-handle s did))
       (cond
         [(eq? h (session-doc-applied s did)) s]
         [else
          (define text (session-document-string s did))
          (define fills (append* (for/list ([p (in-list ps)])
                                   ((doc-plugin-fills p) text path))))
          (session-doc-mark-applied (session-doc-face! s did fills) did h)])])))
