#lang racket

;;; lab-rebuild/kernel/session.rkt —— 会话状态（不可变值；editor 内部可变）。
;;;
;;; 两种焦点分离：
;;;   focus     输入焦点（谁的键表生效、字符往哪打）——可以是主区叶或 dock
;;;   edit-vid  活动编辑视图（粘性）——只在 focus 落在主区叶时更新
;;;   input     输入层栈（layer：前缀 / 菜单 / 浮层模态）
;;; 派生量不进真身；feature 状态（路径 / 脏 / …）放 runtime.services，不进 session。

(require "focus.rkt" "workspace.rkt" "layer.rkt")

(provide (struct-out session) make-session session-focus-vid)

(struct session
  (editor     ; core editor 值（固定层，内部有 box）
   workspace  ; workspace = main(frame) + docks
   focus      ; focus 值（输入焦点）
   edit-vid   ; 活动编辑视图（粘性）；accessor = session-edit-vid
   keys       ; 主区（编辑）键表
   global     ; 全局键表（dock 上也要生效）
   width height
   input      ; 输入层栈（layer-stack）
   awaiting   ; hash id -> (list version current? on-result)  异步版本闸门挂起
   quit?)
  #:transparent)

(define (make-session editor workspace focus edit-vid keys global width height
                      [input (stack-empty)])
  (session editor workspace focus edit-vid keys global width height input (hash) #f))

(define (session-focus-vid s) (focus-target (session-focus s)))
