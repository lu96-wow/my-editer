#lang racket

;;; edit/command/command.rkt —— 命令层（功能使用）
;;;
;;; 命令 = cmd-* 数据 + step 派发。step 只把每条命令翻译成 session.rkt 里的
;;; **操作原语**；实现细节（core、几何、渲染）都在 session.rkt，命令层看不到。
;;;
;;; 这里只 require 实现里**命令需要的那几个**操作函数（窄依赖）——「功能实现」
;;; 与「功能使用」分开：多个函数在 session.rkt，命令只取它用的。
;;;
;;; step 是纯转换 session × cmd -> session；副作用（读事件 / 写屏）在 edit/tui.rkt。

(require (only-in "session.rkt"
                  session-focus-move session-scroll session-toggle-slot
                  session-resize session-quit
                  session-insert session-delete session-backspace
                  session-undo session-redo))

;;; ---------- 命令 ----------

(struct cmd-focus (dir) #:transparent)      ; dir : 'left 'right 'up 'down
(struct cmd-scroll (n) #:transparent)       ; 滚焦点视图 n 个视觉行
(struct cmd-toggle (slot) #:transparent)    ; 切换 bindings 里某个洞（叶）的显隐
(struct cmd-quit () #:transparent)
(struct cmd-resize (w h) #:transparent)

;; document 命令
(struct cmd-insert (text) #:transparent)
(struct cmd-delete () #:transparent)
(struct cmd-backspace () #:transparent)
(struct cmd-undo () #:transparent)
(struct cmd-redo () #:transparent)

(provide (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-toggle)
         (struct-out cmd-quit) (struct-out cmd-resize)
         (struct-out cmd-insert) (struct-out cmd-delete) (struct-out cmd-backspace)
         (struct-out cmd-undo) (struct-out cmd-redo)
         step)

;;; ---------- 纯派发：命令 -> 操作原语 ----------

(define (step s cmd)
  (cond
    [(cmd-focus? cmd)     (session-focus-move s (cmd-focus-dir cmd))]
    [(cmd-scroll? cmd)    (session-scroll s (cmd-scroll-n cmd))]
    [(cmd-toggle? cmd)    (session-toggle-slot s (cmd-toggle-slot cmd))]
    [(cmd-resize? cmd)    (session-resize s (cmd-resize-w cmd) (cmd-resize-h cmd))]
    [(cmd-quit? cmd)      (session-quit s)]
    [(cmd-insert? cmd)    (session-insert s (cmd-insert-text cmd))]
    [(cmd-delete? cmd)    (session-delete s)]
    [(cmd-backspace? cmd) (session-backspace s)]
    [(cmd-undo? cmd)      (session-undo s)]
    [(cmd-redo? cmd)      (session-redo s)]
    [else s]))
