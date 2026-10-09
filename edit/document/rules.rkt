#lang racket

;;; edit/document/rules.rkt —— 文件 → 文档绑定层
;;;
;;; 规则是组装期 config（像键表一样），由 document 打开流程调用：
;;;     rule    = (name match? apply)
;;;     match?  : path -> boolean
;;;     apply   : session did path -> session
;;;
;;; 默认规则只做一件事：把「文件适用的 document 插件」绑到该文档。
;;; 「哪些文件参与」是各插件 applies? 的单一来源，rules 不重复判断，只负责在
;;; open 时执行绑定（会话侧按 did 存绑定，渲染前再懒算 fills）。
;;; 以后可扩展只读 / mode / face / 语言等贡献。

(require "../session.rkt"
         "../plugin/registry.rkt"
         "../plugin/catalog.rkt")

(provide (struct-out rule)
         rules-for rules-apply
         default-rules)

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

;; 默认规则集：绑 document 插件（applies? 过滤）。
(define default-rules
  (list
   (rule 'doc-plugins
         (lambda (path) #t)
         (lambda (s did path)
           (session-doc-bind-plugins
            s did
            (plugins-for enabled-doc-plugins path (session-document-string s did)))))))
