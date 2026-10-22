#lang racket

;;; edit-tui-rebuild/pair/commands.rkt —— 括号自动配对命令
;;;
;;; 命令只产生 view-action：
;;;   insert "()" + nav left
;;; 不碰 engine；runtime 顺序解释后光标落在括号中间。

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "../edit/api.rkt")

(provide auto-pair-command
         auto-pair-paren-command
         auto-pair-bracket-command
         auto-pair-brace-command)

(define (auto-pair-command open close)
  (λ (state)
    (define vid (focus-editor-view state))
    (cond
      [(not vid)
       (values (app-state-with-flash state "pair: 焦点不是 editor") '())]
      [else
       (values state
               (list (view-action 'insert vid
                                  (string->bytes/utf-8
                                   (string-append open close)))
                     (view-action 'nav vid (list 'left #f))))])))

(define auto-pair-paren-command (auto-pair-command "(" ")"))
(define auto-pair-bracket-command (auto-pair-command "[" "]"))
(define auto-pair-brace-command (auto-pair-command "{" "}"))
