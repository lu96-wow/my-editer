#lang racket

;;; edit/document/rules.rkt —— 规则层（纯）
;;;
;;; 逻辑层次：属于**文件打开 / 文档域**，不是会话状态。作用是把「文件」映射到
;;; 该 document 的贡献（主要是**命令表** doc-keymap，以后可扩展只读 / mode / face / 语言）。
;;;
;;; 规则是组装期 config（像键表一样），由 document 打开流程调用，不进 session 真身。
;;;
;;;     rule    = (name match? apply)
;;;     match?  : path -> boolean
;;;     apply   : session did path -> session      ; 贡献（如 session-doc-set-keys）
;;;
;;; 默认规则集**先留空**，接真实 I/O 时再填（.rkt / .txt / …）。

(require racket/path)

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

;; 默认规则集（先留空）。
(define default-rules '())
