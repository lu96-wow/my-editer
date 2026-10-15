#lang racket

;;; command/mouse.rkt —— 鼠标令牌（纯，不碰 tui）
;;;
;;; (mouse action button 修饰…)  相等用 equal?。
;;;   action : 'press | 'release | 'move | 'scroll
;;;   button : 'left 'middle 'right（press/release）| 'up 'down（scroll）| #f（move）
;;;
;;; **严格匹配修饰符**（和 key 一样）：默认无修饰；带修饰要显式写，
;;; 例如 (mouse 'press 'left 'ctrl) 只匹配 Ctrl+左键，普通左键不触发。
;;;
;;; 鼠标没有序列（单 token 直接命中）；**位置不进 token**，进 handler 的 ctx。
;;; 表和键共用 keymap（token 无关）：(keys [(mouse 'press 'left) (λ () …)])。

(provide mouse mouse? mouse-action mouse-button mouse-mods mouse->string
         mouse-actions mouse-buttons)

(require "key.rkt")

(define mouse-actions '(press release move scroll))
;; scroll 用 'up/'down，press/release 用 'left/'middle/'right；move 无 button。
(define mouse-buttons '(left middle right up down))

(struct mouse-token (action button mods) #:transparent)

(define (mouse action button . mods)
  (unless (memq action mouse-actions)
    (error 'mouse "action 要是 ~a 之一：~a" mouse-actions action))
  (cond
    [(eq? action 'move)
     (when button (error 'mouse "move 没有 button（传 #f）：~a" button))]
    [else
     (unless (memq button mouse-buttons)
       (error 'mouse "button 要是 ~a 之一：~a" mouse-buttons button))])
  (mouse-token action button (normalize-mods mods)))

(define mouse? mouse-token?)
(define mouse-action mouse-token-action)
(define mouse-button mouse-token-button)
(define mouse-mods mouse-token-mods)

(define (mouse->string m)
  (string-append
   (if (memq 'ctrl (mouse-mods m)) "C-" "")
   (if (memq 'alt (mouse-mods m)) "M-" "")
   (if (memq 'shift (mouse-mods m)) "S-" "")
   (if (mouse-button m) (symbol->string (mouse-button m)) "-")
   " " (symbol->string (mouse-action m))))
