#lang racket

;;; edit4/app.rkt —— 装配（基础 + 内容命令/键表/作用域/面板）+ boot 底盘

(provide app-commands app-keymap app-scopes app-panels boot)

(require "core/world.rkt" "core/command.rkt" "core/keymap.rkt" "core/dispatch.rkt" "core/commands.rkt"
         "content/content.rkt" "content/commands.rkt"
         "view/panels.rkt"
         "layout.rkt")

(define (app-commands) (command-registry-merge base-commands content-commands))
(define (app-keymap) (compose-keymaps (list base-keymap content-keymap)))
(define (app-scopes) base-scopes)
(define (app-panels) base-panels)

;; boot：侧栏(树) | 主区(编辑器 / 状态栏)。
;;   id 2 = 树（固定 28），id 0 = 编辑器（弹性），id 1 = 状态栏（固定 1 行）。
(define (boot #:text [text ""] #:name [name "*scratch*"] #:path [path #f]
              #:root [root (current-directory)])
  (define c0 (content-blank))
  (define-values (c1 _did-ed vid-ed) (content-add-doc! c0 text 60 22 name path))
  (define-values (c2 _did-tr vid-tr) (content-add-panel! c1 "*tree*" 28 24))
  (define-values (c3 _did-st vid-st) (content-add-panel! c2 "*status*" 60 1))
  (define right (split 'v 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                  (child (size 1 #f) (leaf 1 (cons 1 1))))))
  (define chassis (split 'h 1 (list (child (size 28 #f) (leaf 2 (cons 1 1)))
                                    (child (size 1 #t) right))))
  (define c (content-bind (content-bind (content-bind c3 0 vid-ed) 1 vid-st) 2 vid-tr))
  (refresh-tree! (make-world #:layout chassis #:focus 0 #:content c) #:root root))
