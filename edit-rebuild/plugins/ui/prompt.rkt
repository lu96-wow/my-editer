#lang racket

;;; edit-rebuild/plugins/ui/prompt.rkt —— 输入行插件（停靠面，1 行，与 status / log 互斥）
;;;
;;; 提供输入行面板，并处理 cmd-prompt-open：先显示自己的面板，再调内核的
;;; session-prompt-open。其它插件只需 `(step s (cmd-prompt-open label on-submit))`，
;;; 不 require 本插件。

(require "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "ids.rkt")

(provide prompt-spec)

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

(define (prompt-handler)
  (lambda (s cmd)
    (cond
      [(cmd-prompt-open? cmd)
       (define vid (session-panel-vid s panel-input))
       (cond
         [(not vid) s]
         [else
          (session-prompt-open (session-region-select s slot-bottom panel-input)
                               vid
                               (cmd-prompt-open-label cmd)
                               (cmd-prompt-open-on-submit cmd))])]
      [else #f])))

(define (prompt-install s)
  (define-values (s1 _did vid)
    (session-add-document s "" (session-width s) 1 #:name "*input*"))
  (define sf (dock-surface panel-input vid #f input-keys slot-bottom 'height 1))
  (session-add-handler (session-set-visible (session-add-surface s1 sf) vid #f)
                       (prompt-handler)))

(define prompt-spec (plugin-spec 'prompt prompt-install '()))
