#lang racket

;;; edit4/app.rkt —— 装配（基础 + 内容命令/键表/作用域）+ boot

(provide app-commands app-keymap app-scopes boot)

(require "core/world.rkt" "core/command.rkt" "core/keymap.rkt" "core/dispatch.rkt" "core/commands.rkt"
         "content/content.rkt" "content/commands.rkt"
         "layout.rkt")

(define (app-commands) (command-registry-merge base-commands content-commands))
(define (app-keymap) (compose-keymaps (list base-keymap content-keymap)))
(define (app-scopes) base-scopes)

;; boot : 一个空窗 + 一个文档（可能是文件或 scratch）绑定到窗口 0。
(define (boot #:text [text ""] #:name [name "*scratch*"] #:path [path #f])
  (define c0 (content-blank))
  (define-values (c _did vid) (content-add-doc! c0 text 40 10 name path))
  (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c 0 vid)))
