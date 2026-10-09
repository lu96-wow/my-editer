#lang racket

;;; edit/session/doc.rkt —— 文档域会话状态（纯）
;;;
;;; did <-> path、保存句柄、文档级键表。全部纯（doc-state / keymap 都是 core 纯模块）。
;;; 脏仍由 core.rkt 依「保存句柄 vs 当前句柄」派生。
;;;
;;; 同层：core.rkt（借保存句柄算脏）、结构手术（关文档时清）、document 特征。

(require "value.rkt"
         "../core/doc-state.rkt"
         "../core/keymap.rkt")

(provide session-file-path session-file-did session-file-dids session-set-file
         session-saved session-set-saved session-clear-doc
         session-doc-keys session-doc-set-keys
         session-doc-plugins session-doc-bind-plugins
         session-doc-applied session-doc-mark-applied)

;;; ---------- did <-> path ----------

(define (session-file-path s did) (doc-state-path (session-docs s) did))
(define (session-file-did s path) (doc-state-did (session-docs s) path))
(define (session-file-dids s) (doc-state-dids (session-docs s)))
(define (session-set-file s did path)
  (struct-copy session s [docs (doc-state-set-path (session-docs s) did path)]))

;;; ---------- 保存句柄 ----------

(define (session-saved s did) (doc-state-saved (session-docs s) did))
(define (session-set-saved s did h)
  (struct-copy session s [docs (doc-state-set-saved (session-docs s) did h)]))
(define (session-clear-doc s did)
  (struct-copy session s [docs (doc-state-remove (session-docs s) did)]))

;;; ---------- 文档级键表 ----------

(define (session-doc-keys s did) (hash-ref (session-doc-keymaps s) did (kbd)))
;; 整表替换（规则层用：文件打开匹配命令表）。
(define (session-doc-set-keys s did km)
  (struct-copy session s [doc-keymaps (hash-set (session-doc-keymaps s) did km)]))

;;; ---------- document 插件绑定 / 写回缓存 ----------

(define (session-doc-plugins s did) (doc-state-plugins (session-docs s) did))
(define (session-doc-bind-plugins s did ps)
  (struct-copy session s [docs (doc-state-set-plugins (session-docs s) did ps)]))

(define (session-doc-applied s did) (doc-state-applied (session-docs s) did))
(define (session-doc-mark-applied s did h)
  (struct-copy session s [docs (doc-state-set-applied (session-docs s) did h)]))
