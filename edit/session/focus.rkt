#lang racket

;;; edit/session/focus.rkt —— 焦点（set）
;;;
;;; focus = 输入焦点。edit-vid 是粘性活动编辑视图：只在焦点落到**非状态窗口**时更新。
;;; 单独一层，让 panel / bottom / structure / mouse 不必互相依赖。

(require "value.rkt"
         "../core/focus.rkt")

(provide session-set-focus)

(define (session-set-focus s f)
  (define vid (focus-target f))
  (define edit (if (and vid (not (session-dock-vid? s vid))) vid (session-edit-vid s)))
  (struct-copy session s [focus f] [edit-vid edit]))
