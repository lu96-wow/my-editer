#lang racket

;;; edit-tui-rebuild/edit/insert.rkt —— 自插入判读（纯）
;;;
;;; 只做「这个键该当成什么编辑动作」的判读，不碰 State / engine。
;;;
;;; 命名键（enter / tab / backspace / arrows …）由命令表显式绑定；
;;; 这里只补「任意可打印字符」这一条表里写不下的兜底。

(require "../core/skeleton.rkt")

(provide self-insert-text
         self-insert-char
         self-insert-bytes)

;; 可打印键 -> 插入文本。token 已经是 (tag . bytes)：
;;   'key / 'utf8  -> bytes 就是终端送的那串，只在这里解一次 UTF-8
;;   'ctrl / 'alt / 'mod-seq / 命名键 -> #f（不当文本插入）
(define (self-insert-text tok)
  (and (key? tok) (key-text tok)))

;; 要字符而不是串时用（便利包装）。
(define (self-insert-char tok)
  (define s (self-insert-text tok))
  (and s (string-ref s 0)))

;; 原始字节（insert action 直接带 bytes，engine 解码一次）。
;; 以 self-insert-text 为准：'key 必须正好 1 个可打印字节，不能把
;; 误标成 'key 的转义序列整串塞进 buffer。
(define (self-insert-bytes tok)
  (and (self-insert-text tok) (key-bytes tok)))
