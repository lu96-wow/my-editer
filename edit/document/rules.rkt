#lang racket

;;; edit/document/rules.rkt —— 文件 → 文档绑定**机制**（纯）
;;;
;;; 规则是组装期 config（像键表一样），由 document 打开流程调用：
;;;     rule    = (name match? apply)
;;;     match?  : path -> boolean
;;;     apply   : session did path -> session
;;;
;;; 本模块只提供机制，不含任何默认规则集 —— 「默认规则」由**装配层**注入
;;; （见 plugin/bind.rkt 的 doc-plugin-rule + app 组装），于是 document 层
;;; 不依赖任何具体插件实现。

(provide (struct-out rule)
         rules-for rules-apply)

(struct rule (name match? apply) #:transparent)
;; name  : symbol
;; match? : path -> boolean
;; apply  : session did path -> session

;; 命中的规则（按列表顺序）。
(define (rules-for rules path)
  (for/list ([r (in-list rules)] #:when ((rule-match? r) path)) r))

;; 依次施加命中规则的贡献。
(define (rules-apply rules s did path)
  (for/fold ([s s]) ([r (in-list (rules-for rules path))])
    ((rule-apply r) s did path)))
