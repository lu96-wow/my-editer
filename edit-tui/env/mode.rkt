#lang racket

;;; env/mode.rkt —— document 模式（原 doc-kind）→ 默认 keymap + fallback（纯值）
;;; layer  : env
;;; effect : 无（纯值）

;;; mode 名是开放 symbol，存在 environment 的 modes 表；结构不带名字（表键即名字）。
;;;
;;;   keymaps : (listof keymap)  有序；前面的层优先（第一个非 unbound 胜出）
;;;   fallback: 'insert | 'ignore
;;;             'insert  = 未命中且是可打印字符 -> 插入文本
;;;             'ignore  = 未命中不插入（只读 viewer / 状态栏 / 树）
;;;
;;; 未注册 mode -> mode-default（空表 + 'ignore），这样“有文档但没配表”不会误插入。

(provide (struct-out mode)
         make-mode
         mode-default)

(require "../base/keymap.rkt")

(struct mode (keymaps fallback) #:transparent)
;; keymaps : (listof keymap)
;; fallback: 'insert | 'ignore

(define (make-mode #:keymaps [keymaps '()] #:fallback [fallback 'ignore])
  (unless (memq fallback '(insert ignore))
    (error 'make-mode "fallback 要是 insert/ignore：~a" fallback))
  (for ([km (in-list keymaps)])
    (unless (keymap? km)
      (error 'make-mode "keymaps 里要 keymap：~a" km)))
  (mode keymaps fallback))

(define mode-default (make-mode))
