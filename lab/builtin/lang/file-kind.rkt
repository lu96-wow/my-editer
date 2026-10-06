#lang racket

;;; lab-rebuild/lang/file-kind.rkt —— 文档类型判定（纯原子）
;;;
;;; 「哪些文件算 Racket 源文件」的单一来源：高亮插件用它声明 `applies?`，
;;; 补全用它决定是否启用。按扩展名判断。

(provide racket-exts racket-file? racket-applies?)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (member (path-get-extension path) racket-exts)))

;; plugin.applies? 协议是 (path text) -> bool；按扩展名判断只需 path。
(define (racket-applies? path text) (racket-file? path))
