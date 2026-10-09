#lang racket

;;; edit/core/doc-state.rkt —— 文档域状态（纯）：did <-> path + 保存句柄
;;;
;;; 把「文件映射」与「脏标记（保存时的 document 句柄）」合成一个值，挂在 session.docs。
;;; 通用编辑器真身（core editor）不揣这些；本模块是文档/资源域的纯数据。
;;; （插件绑定 / 写回缓存属插件层，见 session/plugin.rkt，不在这里。）

(require "file-map.rkt")

(provide (struct-out doc-state)
         doc-state-empty
         doc-state-path doc-state-did doc-state-dids
         doc-state-set-path doc-state-remove
         doc-state-saved doc-state-set-saved)

(struct doc-state (files saved-handles) #:transparent)
;; files         : file-map                  did <-> path
;; saved-handles : (hash did -> handle)      保存时的文档句柄（脏 = 当前句柄 != saved）

(define (doc-state-empty) (doc-state (file-map-empty) (hash)))

(define (doc-state-path ds did) (file-map-path (doc-state-files ds) did))
(define (doc-state-did ds path) (file-map-did (doc-state-files ds) path))
(define (doc-state-dids ds) (file-map-dids (doc-state-files ds)))

(define (doc-state-set-path ds did path)
  (struct-copy doc-state ds [files (file-map-add (doc-state-files ds) did path)]))

(define (doc-state-saved ds did) (hash-ref (doc-state-saved-handles ds) did #f))
(define (doc-state-set-saved ds did h)
  (struct-copy doc-state ds [saved-handles (hash-set (doc-state-saved-handles ds) did h)]))

;; 删除该 did 的全部文档域状态（关文档时）。
(define (doc-state-remove ds did)
  (struct-copy doc-state ds
    [files (file-map-remove (doc-state-files ds) did)]
    [saved-handles (hash-remove (doc-state-saved-handles ds) did)]))
