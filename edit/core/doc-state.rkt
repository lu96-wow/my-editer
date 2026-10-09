#lang racket

;;; edit/core/doc-state.rkt —— 文档域状态（纯）：did <-> path + 保存句柄 + 插件绑定
;;;
;;; 把「文件映射」「脏标记（保存时的 document 句柄）」「该文档的 document 插件绑定 /
;;; 已写回句柄」合成一个值，挂在 session.docs。
;;; 通用编辑器真身（core editor）不揣这些；本模块是文档/资源域的纯数据。

(require "file-map.rkt")

(provide (struct-out doc-state)
         doc-state-empty
         doc-state-path doc-state-did doc-state-dids
         doc-state-set-path doc-state-remove
         doc-state-saved doc-state-set-saved
         doc-state-plugins doc-state-set-plugins
         doc-state-applied doc-state-set-applied)

(struct doc-state (files saved-handles plugin-bindings applied-handles) #:transparent)
;; files           : file-map                  did <-> path
;; saved-handles   : (hash did -> handle)      保存时的文档句柄（脏 = 当前句柄 != saved）
;; plugin-bindings : (hash did -> (listof doc-plugin))  该文档适用的 document 插件
;; applied-handles : (hash did -> handle)      上次写回 fills 时的文档句柄（判新旧，lazy）

(define (doc-state-empty) (doc-state (file-map-empty) (hash) (hash) (hash)))

(define (doc-state-path ds did) (file-map-path (doc-state-files ds) did))
(define (doc-state-did ds path) (file-map-did (doc-state-files ds) path))
(define (doc-state-dids ds) (file-map-dids (doc-state-files ds)))

(define (doc-state-set-path ds did path)
  (struct-copy doc-state ds [files (file-map-add (doc-state-files ds) did path)]))

(define (doc-state-saved ds did) (hash-ref (doc-state-saved-handles ds) did #f))
(define (doc-state-set-saved ds did h)
  (struct-copy doc-state ds [saved-handles (hash-set (doc-state-saved-handles ds) did h)]))

(define (doc-state-plugins ds did) (hash-ref (doc-state-plugin-bindings ds) did '()))
(define (doc-state-set-plugins ds did ps)
  (struct-copy doc-state ds [plugin-bindings (hash-set (doc-state-plugin-bindings ds) did ps)]))

(define (doc-state-applied ds did) (hash-ref (doc-state-applied-handles ds) did #f))
(define (doc-state-set-applied ds did h)
  (struct-copy doc-state ds [applied-handles (hash-set (doc-state-applied-handles ds) did h)]))

;; 删除该 did 的全部文档域状态（关文档时）。
(define (doc-state-remove ds did)
  (struct-copy doc-state ds
    [files (file-map-remove (doc-state-files ds) did)]
    [saved-handles (hash-remove (doc-state-saved-handles ds) did)]
    [plugin-bindings (hash-remove (doc-state-plugin-bindings ds) did)]
    [applied-handles (hash-remove (doc-state-applied-handles ds) did)]))
