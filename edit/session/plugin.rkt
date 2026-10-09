#lang racket

;;; edit/session/plugin.rkt —— document 插件绑定 / 状态 / 写回（会话侧）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来。
;;; 状态：每个 did 一份 (hash 插件名 -> state)，与「已写回句柄」一起缓存。
;;; 写回：渲染前对绑了插件、且文档句柄变了的文档，用旧 state 跑各插件 → 新 state + fills，
;;;       写 face 端口并把新 state 存回。
;;;   · 引擎每次编辑自动 rebase face 端口并产生新句柄 →「句柄变了」= 文本变了
;;;     （undo 同理），所以 lazy 判据就是句柄比较，不需要捕获 change。
;;;   · face 端口写回走 core.rkt 的通用原语 session-doc-face!；本层只认识插件协议。

(require "value.rkt"
         "doc.rkt"
         "core.rkt"
         "../plugin/registry.rkt")

(provide session-doc-plugins session-doc-bind-plugins
         session-doc-applied
         session-doc-plugin-forget
         session-doc-plugins-apply)

;;; ---------- 绑定（纯） ----------

(define (session-doc-plugins s did) (hash-ref (session-plugin-bindings s) did '()))
(define (session-doc-bind-plugins s did ps)
  (struct-copy session s [plugin-bindings (hash-set (session-plugin-bindings s) did ps)]))

;;; ---------- 状态 + 写回缓存 ----------
;; plugin-applied : hash did -> (cons handle (hash 插件名 -> state))

(define (session-doc-applied s did)
  (define e (hash-ref (session-plugin-applied s) did #f))
  (and e (car e)))

(define (session-doc-plugin-states s did)
  (define e (hash-ref (session-plugin-applied s) did #f))
  (if e (cdr e) (hash)))

(define (session-doc-mark-applied s did h states)
  (struct-copy session s
    [plugin-applied (hash-set (session-plugin-applied s) did (cons h states))]))

;; 关文档时清掉该 did 的绑定与缓存。
(define (session-doc-plugin-forget s did)
  (struct-copy session s
    [plugin-bindings (hash-remove (session-plugin-bindings s) did)]
    [plugin-applied (hash-remove (session-plugin-applied s) did)]))

;;; ---------- 渲染前写回 ----------

;; 焦点视图（若属于该 did）的光标 → (cons line col) | #f。
(define (session-doc-focus-point s did)
  (define vid (session-focus-vid s))
  (cond
    [(and vid (eqv? did (session-view-did s vid)))
     (cons (session-view-point-line s vid) (session-view-point-column s vid))]
    [else #f]))

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
          (define ctx (doc-ctx (session-document-string s did) path
                               (session-doc-focus-point s did)))
          (define states0 (session-doc-plugin-states s did))
          (define-values (states fills)
            (for/fold ([st states0] [fl '()]) ([p (in-list ps)])
              (define name (doc-plugin-name p))
              (define-values (st* fl*) ((doc-plugin-run p) (hash-ref st name #f) ctx))
              (values (hash-set st name st*) (append fl fl*))))
          (session-doc-mark-applied (session-doc-face! s did fills) did h states)])])))
