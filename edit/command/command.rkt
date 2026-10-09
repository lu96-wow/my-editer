#lang racket

;;; edit/command/command.rkt —— 命令层（功能使用）
;;;
;;; 命令 = cmd-* 数据 + step 派发。step 只把每条命令翻译成 session.rkt 里的
;;; **操作原语**；实现细节（core、几何、渲染）都在 session.rkt。
;;;
;;; 命令分两处：
;;;   · 基础命令（本文件）：焦点 / 滚动 / 导航 / 编辑 / 输入行 / 状态窗口轮换
;;;   · feature 命令：feature 自带 cmd-* + handler，挂在 session 的 handler 链上，
;;;     step 先跑 handler 链，再落到基础命令。
;;;
;;; 这里只 require 实现里**命令需要的那几个**操作函数（窄依赖）。

(require (only-in "session.rkt"
                  session-focus-move session-scroll session-toggle-slot
                  session-resize session-quit session-nav
                  session-insert session-delete session-backspace
                  session-undo session-redo
                  session-prompt-submit session-prompt-cancel
                  session-panel-swap session-handlers))

;;; ---------- 基础命令 ----------

(struct cmd-focus (dir) #:transparent)      ; 焦点几何移动
(struct cmd-scroll (n) #:transparent)       ; 滚焦点视图 n 个视觉行
(struct cmd-nav (dir extend?) #:transparent); 文本光标移动
(struct cmd-toggle (slot) #:transparent)    ; 切换 bindings 里某个洞（叶）的显隐
(struct cmd-panel-swap () #:transparent)    ; 同位置状态窗口互换（Tab）
(struct cmd-quit () #:transparent)
(struct cmd-resize (w h) #:transparent)

;; document 命令
(struct cmd-insert (text) #:transparent)
(struct cmd-delete () #:transparent)
(struct cmd-backspace () #:transparent)
(struct cmd-undo () #:transparent)
(struct cmd-redo () #:transparent)

;; 输入行
(struct cmd-prompt-submit () #:transparent)
(struct cmd-prompt-cancel () #:transparent)

(provide (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-nav)
         (struct-out cmd-toggle) (struct-out cmd-panel-swap)
         (struct-out cmd-quit) (struct-out cmd-resize)
         (struct-out cmd-insert) (struct-out cmd-delete) (struct-out cmd-backspace)
         (struct-out cmd-undo) (struct-out cmd-redo)
         (struct-out cmd-prompt-submit) (struct-out cmd-prompt-cancel)
         step)

;;; ---------- 派发：feature handler 链 -> 基础命令 ----------

(define (step s cmd)
  (or (for/or ([h (in-list (session-handlers s))]) (h s cmd))
      (step-base s cmd)))

(define (step-base s cmd)
  (cond
    [(cmd-focus? cmd)     (session-focus-move s (cmd-focus-dir cmd))]
    [(cmd-scroll? cmd)    (session-scroll s (cmd-scroll-n cmd))]
    [(cmd-nav? cmd)       (session-nav s (cmd-nav-dir cmd) (cmd-nav-extend? cmd))]
    [(cmd-toggle? cmd)    (session-toggle-slot s (cmd-toggle-slot cmd))]
    [(cmd-panel-swap? cmd) (session-panel-swap s)]
    [(cmd-resize? cmd)    (session-resize s (cmd-resize-w cmd) (cmd-resize-h cmd))]
    [(cmd-quit? cmd)      (session-quit s)]
    [(cmd-insert? cmd)    (session-insert s (cmd-insert-text cmd))]
    [(cmd-delete? cmd)    (session-delete s)]
    [(cmd-backspace? cmd) (session-backspace s)]
    [(cmd-undo? cmd)      (session-undo s)]
    [(cmd-redo? cmd)      (session-redo s)]
    [(cmd-prompt-submit? cmd) (session-prompt-submit s)]
    [(cmd-prompt-cancel? cmd) (session-prompt-cancel s)]
    [else s]))
