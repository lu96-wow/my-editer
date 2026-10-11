#lang racket

;;; core/mode.rkt —— 路径 → document 键表的**匹配层**（纯）
;;;
;;; 打开 / 定位一个文件时，按配置的 matcher 列表找第一个命中的，把它的键表挂到该
;;; document 上。这是给「插件层」预留的接入点：插件只要往配置里加 (matcher . 表)
;;; 就能让某类文件带上自己的命令表；core 只做匹配，不认识具体模式。
;;;
;;; matcher 是**纯数据**（不 require 实现）：
;;;   (ext "rkt")         扩展名（不含点）
;;;   (name "Makefile")   文件名
;;;   (regexp "…")        整个路径的正则
;;;   (any)               总是命中（兜底）
;;; matchers : (listof (cons matcher 键表))，顺序 = 优先级。

(provide matcher-match? match-doc-keys)

(require racket/path
         racket/string)

;; 扩展名（不含点）；无扩展名 → #f。
(define (path-ext path)
  (define e (path-get-extension path))
  (and e (let ([s (bytes->string/utf-8 e)])
           (and (>= (string-length s) 1) (substring s 1)))))

(define (path-name path)
  (define f (file-name-from-path path))
  (and f (path->string f)))

(define (matcher-match? m path)
  (case (car m)
    [(ext)    (equal? (cadr m) (path-ext path))]
    [(name)   (equal? (cadr m) (path-name path))]
    [(regexp) (regexp-match? (regexp (cadr m)) (path->string path))]
    [(any)    #t]
    [else #f]))

;; 第一个命中的 matcher 的表；无 → #f。
(define (match-doc-keys path matchers)
  (for/first ([mp (in-list matchers)] #:when (matcher-match? (car mp) path))
    (cdr mp)))
