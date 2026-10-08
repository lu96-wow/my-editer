#lang racket

;;; lab-rebuild/builtin/lang/file-kind.rkt —— 文档类型判定（纯原子）。
;;;
;;; 「哪些文件算 Racket 源文件」的单一来源：缩进 / 补全 / 文档查询共用。
;;; 按扩展名判断。

(provide racket-exts racket-file? racket-applies? racket-buffer?)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (if (member (path-get-extension path) racket-exts) #t #f)))

;; 插件协议 (path text) -> bool；按扩展名判断只需 path。
;; 插件只对真实文件跑，故无路径 = 不适用。
(define (racket-applies? path text) (racket-file? path))

;; 功能级（缩进 / 补全 / 文档查询）：无路径的 scratch 也允许，有路径须是 Racket。
;; 谓词吃 (path get-text)；本谓词只看扩展名，不 force get-text。
(define (racket-buffer? path get-text) (or (not path) (racket-file? path)))
