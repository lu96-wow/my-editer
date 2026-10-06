#lang racket

;;; lab-rebuild/platform/command.rkt —— 命令注册表机制（平台骨架）
;;;
;;; 平台只提供**机制**：命令名（symbol）→ handler，handler 统一是
;;;   (event app . args) -> any
;;; 「有哪些命令 / 命令干什么」由内置命令模块和插件用 `command-register!` 注册。
;;;
;;; 命令描述（command spec，来自 keymap）：
;;;   spec = symbol              （命令名）
;;;        | (list symbol arg …)  （带参数：如 (prefix "C-p" table) / (insert-string "\n")）
;;;
;;; 本文件不认识 core / 焦点 / 键位 / 插件：只维护一张 symbol -> handler 表。

(provide command-register! command-registered? command-invoke
         define-command)

(define commands (make-hash))   ; symbol -> handler

;; 注册（可被内置命令 / 插件反复调用；同名后注册覆盖先注册）。
(define (command-register! name proc)
  (unless (symbol? name) (error 'command-register! "命令名必须是 symbol，得到 ~a" name))
  (unless (procedure? proc) (error 'command-register! "handler 必须是过程，得到 ~a" proc))
  (hash-set! commands name proc))

(define (command-registered? name) (hash-has-key? commands name))

;; 便捷宏： (define-command insert cmd-insert)
(define-syntax-rule (define-command name proc)
  (command-register! 'name proc))

;; spec = name | (name . args)（见 platform/keymap.rkt）
(define (command-invoke spec event app)
  (define name (if (pair? spec) (car spec) spec))
  (define args (if (pair? spec) (cdr spec) '()))
  (define h (hash-ref commands name #f))
  (unless h (error 'command-invoke "未知命令: ~a" name))
  (apply h event app args))
