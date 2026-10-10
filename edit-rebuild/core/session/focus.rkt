#lang racket

;;; edit-rebuild/core/session/focus.rkt —— 焦点机制
;;;
;;; 局部问题：设输入焦点。focus 值本体在 ../focus.rkt（纯）；这里加两条会话语义：
;;;   · 粘性 edit-vid —— 焦点落到**非面**时更新为焦点 vid，落到面（dock/浮窗）时不变；
;;;   · 发 'focus-changed (vid)。
;;;
;;; 单独一层，让 structure / mouse / panel 不必互相依赖。

(require "session.rkt"
         "input-state.rkt"
         "hook.rkt"
         "../focus.rkt")

(provide session-set-focus)

(define (session-set-focus s f)
  (define vid (focus-target f))
  (define edit (if (and vid (not (session-dock-vid? s vid))) vid (session-edit-vid s)))
  (define s1 (struct-copy session s
               [input (input-state-set-edit-vid
                       (input-state-set-focus (session-input s) f) edit)]))
  (session-run-hooks s1 'focus-changed (list vid)))
