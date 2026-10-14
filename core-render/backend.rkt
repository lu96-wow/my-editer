#lang racket

;;; core-render/backend.rkt —— 后端原语入口（唯一分叉点）
;;;
;;; render.rkt / theme.rkt 只 require 这里，不直接 require tui。
;;; 换后端只改下一行的 require 路径：
;;;     tui       真终端后端（默认）
;;;     tui/char  字符图后端（无 TTY，可测 / 无 FFI）
;;;
;;; 两者 format-* / style->bytes / style-define! / put-bytes 同名同签名，
;;; 区别只是片段是 bytes 还是 op-seq。

(require tui)

(provide (all-from-out tui)
         fragment)

;; 片段拼接：真终端拼 bytes，char 后端拼 op-seq（tui/char 的 bytes-append = ops-append）。
;; 自动滤掉 #f；无参时返回各自单位元（#"" / '()）。
(define (fragment . parts)
  (apply bytes-append (filter values parts)))
