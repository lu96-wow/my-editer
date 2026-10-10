#lang racket

;;; edit-rebuild/core/session/docs-state.rkt —— 文档域状态（纯）
;;;
;;; 局部问题：按 did 的文档元数据 —— 台账（path / 保存句柄）、每文档键表、插件绑定。
;;; 台账本体是 doc/catalog.rkt；这里只把「文档域」的几项合成会话里的一个子值。

(require "../doc/catalog.rkt"
         "../keymap.rkt")

(provide (struct-out docs-state)
         docs-state-new
         docs-state-set-catalog
         docs-state-set-keymap
         docs-state-set-plugin-bindings
         docs-state-remove-plugin-binding
         docs-state-remove)

(struct docs-state (catalog keymaps plugin-bindings) #:transparent)
;; catalog         : doc-state            did <-> path + 保存句柄
;; keymaps         : (hash did -> keymap)
;; plugin-bindings : (hash did -> (listof face-plugin))

(define (docs-state-new)
  (docs-state (doc-state-empty) (hash) (hash)))

(define (docs-state-set-catalog d catalog)
  (struct-copy docs-state d [catalog catalog]))

(define (docs-state-set-keymap d did km)
  (struct-copy docs-state d [keymaps (hash-set (docs-state-keymaps d) did km)]))

(define (docs-state-set-plugin-bindings d did ps)
  (struct-copy docs-state d
    [plugin-bindings (hash-set (docs-state-plugin-bindings d) did ps)]))

(define (docs-state-remove-plugin-binding d did)
  (struct-copy docs-state d
    [plugin-bindings (hash-remove (docs-state-plugin-bindings d) did)]))

(define (docs-state-remove d did)
  (struct-copy docs-state d
    [keymaps (hash-remove (docs-state-keymaps d) did)]
    [plugin-bindings (hash-remove (docs-state-plugin-bindings d) did)]))
