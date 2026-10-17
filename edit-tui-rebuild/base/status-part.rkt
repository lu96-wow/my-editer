#lang racket

;;; base/status.rkt —— 状态栏段（纯值）
;;; layer  : base
;;; effect : 无（纯值；render 由使用方提供）

;;; 状态栏 = 若干 status-part 按顺序投影、去掉空串、用分隔符连接。
;;; render : state engine-view -> #f | string
;;; 段由 environment.status 提供；投影层只负责组合。

(provide (struct-out status-part)
         make-status-part)

(struct status-part (name render) #:transparent)
;; name   : symbol
;; render : (state engine-view -> #f | string)

(define (make-status-part name render)
  (unless (symbol? name) (error 'make-status-part "name 要是 symbol：~a" name))
  (unless (procedure? render) (error 'make-status-part "render 要是过程：~a" render))
  (status-part name render))
