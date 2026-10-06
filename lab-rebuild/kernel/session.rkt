#lang racket

;;; lab-rebuild/kernel/session.rkt —— 会话状态（不可变值；editor 内部可变）。
;;;
;;; 每条字段只有一个写入点（kernel 的某个 effect-apply）。
;;; 派生量（layout / active / 有效槽位视图）不进 session 真身。
;;;
;;; 字段只保留「框架状态」；feature 自己的状态放 layer 实例或 runtime.services。

(require "frame.rkt" "focus.rkt" "layer.rkt" "table.rkt" "paths.rkt" "policy.rkt" "panel.rkt")

(provide (struct-out session) make-session
         session-focus-vid)

(struct session
  (editor        ; core editor 值（固定层，内部有 box）
   frame         ; frame 值
   focus         ; focus 值
   input         ; input 值（层栈）
   cs            ; command-set
   paths         ; path-table
   interactions  ; (listof suspension)        挂起的 Interaction
   width height
   sidebar? sidebar-width
   status-vid    ; 底部槽位：状态行视图
   input-vid     ; 底部槽位：输入视图（prompt 占用）
   named         ; hash 表名 -> keytable（基础 + binding 贡献）
   panels        ; (listof panel)  左栏面板
   active-panel  ; symbol / #f    当前显示哪个面板
   awaiting      ; hash id -> (list version current? on-result)  异步版本闸门挂起
   next-sid      ; 挂起 id 分配器（per-session）
   quit?)
  #:transparent)

(define (make-session editor frame focus input cs paths width height status-vid input-vid
                      [named (hash)] [panels '()] [active-panel #f])
  (session editor frame focus input cs paths '() width height #f 24
           status-vid input-vid named panels active-panel (hash) 0 #f))

;; 焦点视图（focus.target 是一个 pane/vid）。
(define (session-focus-vid s) (focus-target (session-focus s)))
