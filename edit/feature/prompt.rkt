#lang racket

;;; edit/feature/prompt.rkt —— 输入行（底部，1 行）
;;;
;;; label 作为只读前缀，用户输入在后；Enter 提交 / Escape 取消。
;;; 打开走 session-prompt-open（feature 调用），提交 / 取消是基础命令。

(require "api.rkt")

(provide prompt-install)

(define input-keys
  (kbd
   text-binding     text-spec
   (key 'backspace) (cmd-backspace)
   (key 'delete)    (cmd-delete)
   (key 'left)      (cmd-nav 'left #f)
   (key 'right)     (cmd-nav 'right #f)
   (key 'home)      (cmd-nav 'home #f)
   (key 'end)       (cmd-nav 'end #f)
   (key 'enter)     (cmd-prompt-submit)
   (key 'escape)    (cmd-prompt-cancel)))

;; → (values session vid)
(define (prompt-install s width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*input*"))
  (define p (panel 'input vid #f input-keys #f))
  (values (session-set-visible (session-add-panel s1 p) vid #f) vid))
