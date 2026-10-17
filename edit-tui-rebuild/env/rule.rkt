#lang racket

;;; env/rule.rkt —— 带 scope 的命令表规则（纯值）
;;;
;;; 一条规则 = scope + keymap。dispatch 按顺序试：
;;;    scope 成立 + keymap 命中 leaf    -> 执行
;;;    scope 成立 + keymap 命中 prefix  -> 继续读键
;;;    scope 不成立 / 未命中             -> 下一条
;;;
;;; 规则由 environment.rules 持有，可以是插件 / 用户加的“有条件的表”。

(provide (struct-out rule)
         make-rule)

(require "../base/keymap.rkt")

(struct rule (scope keymap) #:transparent)
;; scope  : symbol    'always 或 environment.scopes 里的键
;; keymap : keymap

(define (make-rule scope keymap)
  (unless (symbol? scope) (error 'make-rule "scope 要是 symbol：~a" scope))
  (unless (keymap? keymap) (error 'make-rule "keymap 要是 keymap：~a" keymap))
  (rule scope keymap))
