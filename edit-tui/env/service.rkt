#lang racket

;;; layer  : env
;;; effect : 无（纯值）
;;;
;;; env/service.rkt —— worker service 的声明（能力清单）
;;;
;;; worker 的实现仍是 plugins/worker.rkt 的 `service-kinds` / `service-run`；
;;; 这里声明“本 environment 允许 / 使用哪些 kind”，用于：
;;;   · 插件贡献自己的 service kind；
;;;   · 装配期 / startup 校验，避免拼写错误只在运行时才暴露；
;;;   · 文档 / 调试时列出当前能力。
;;;
;;; service-spec 只是元数据，不执行任何东西；payload 仍由 query-effect 携带。

(provide (struct-out service-spec)
         make-service-spec)

(struct service-spec (kind description pure?) #:transparent)
;; kind        : symbol
;; description : string
;; pure?       : bool   是否只做纯计算 / 只读查询（当前 worker 服务都应为 #t）

(define (make-service-spec kind
                           #:description [description ""]
                           #:pure? [pure? #t])
  (unless (symbol? kind)
    (error 'make-service-spec "kind 要是 symbol：~a" kind))
  (unless (string? description)
    (error 'make-service-spec "description 要是 string：~a" description))
  (unless (boolean? pure?)
    (error 'make-service-spec "pure? 要是 boolean：~a" pure?))
  (service-spec kind description pure?))
