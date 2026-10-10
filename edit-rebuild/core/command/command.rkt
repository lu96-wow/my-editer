#lang racket

;;; edit-rebuild/core/command/command.rkt —— 命令值 + 派发
;;;
;;; 局部问题：命令是纯数据（cmd-*）；step 把每条命令翻译成会话模块里的操作原语。
;;; 命令分两处：
;;;   · 基础命令（本文件）：焦点 / 滚动 / 导航 / 编辑 / 输入行 / 面轮换
;;;   · 特性命令：feature 自带 cmd-* + handler，挂在 session 的 handler 链上，
;;;     step 先跑 handler 链，再落到基础命令。

(require (only-in "../session/session.rkt"
                  session-resize session-quit session-handlers session-set-prefix)
         (only-in "../session/edit.rkt"
                  session-focus-move session-scroll session-nav
                  session-insert session-delete session-backspace
                  session-undo session-redo
                  session-select-all session-copy session-cut session-paste)
         (only-in "../session/structure.rkt"
                  session-resize-view session-hide-focused session-split-focused
                  session-toggle-slot)
         (only-in "../session/panel.rkt" session-panel-swap)
         (only-in "../session/prompt.rkt" session-prompt-submit session-prompt-cancel)
         (only-in "../session/mouse.rkt" session-mouse-press session-mouse-scroll))

;;; ---------- 基础命令 ----------

(struct cmd-focus (dir) #:transparent)
(struct cmd-scroll (n) #:transparent)
(struct cmd-nav (dir extend?) #:transparent)
(struct cmd-toggle (slot) #:transparent)
(struct cmd-panel-swap () #:transparent)
(struct cmd-quit () #:transparent)
(struct cmd-close () #:transparent)
(struct cmd-split (axis) #:transparent)
(struct cmd-resize (w h) #:transparent)

(struct cmd-insert (text) #:transparent)
(struct cmd-delete () #:transparent)
(struct cmd-backspace () #:transparent)
(struct cmd-undo () #:transparent)
(struct cmd-redo () #:transparent)
(struct cmd-select-all () #:transparent)
(struct cmd-copy () #:transparent)
(struct cmd-cut () #:transparent)
(struct cmd-paste () #:transparent)

(struct cmd-prompt-open (label on-submit) #:transparent)
(struct cmd-prompt-submit () #:transparent)
(struct cmd-prompt-cancel () #:transparent)
(struct cmd-log-toggle () #:transparent)

(struct cmd-complete () #:transparent)
(struct cmd-complete-move (dir) #:transparent)
(struct cmd-complete-accept () #:transparent)
(struct cmd-complete-cancel () #:transparent)
(struct cmd-complete-switch () #:transparent)
(struct cmd-complete-scroll (delta) #:transparent)
(struct cmd-docs-show () #:transparent)

(struct cmd-resize-view (axis delta) #:transparent)
(struct cmd-prefix (value) #:transparent)
(struct cmd-prefix-cancel () #:transparent)
(struct cmd-mouse-press (col row) #:transparent)
(struct cmd-mouse-scroll (col row delta) #:transparent)

(provide
 (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-nav)
 (struct-out cmd-toggle) (struct-out cmd-panel-swap)
 (struct-out cmd-quit) (struct-out cmd-resize) (struct-out cmd-close)
 (struct-out cmd-split)
 (struct-out cmd-insert) (struct-out cmd-delete) (struct-out cmd-backspace)
 (struct-out cmd-undo) (struct-out cmd-redo)
 (struct-out cmd-select-all) (struct-out cmd-copy) (struct-out cmd-cut) (struct-out cmd-paste)
 (struct-out cmd-prompt-open)
 (struct-out cmd-prompt-submit) (struct-out cmd-prompt-cancel)
 (struct-out cmd-log-toggle)
 (struct-out cmd-complete) (struct-out cmd-complete-move)
 (struct-out cmd-complete-accept) (struct-out cmd-complete-cancel)
 (struct-out cmd-complete-switch) (struct-out cmd-complete-scroll)
 (struct-out cmd-docs-show)
 (struct-out cmd-resize-view)
 (struct-out cmd-prefix) (struct-out cmd-prefix-cancel)
 (struct-out cmd-mouse-press) (struct-out cmd-mouse-scroll)
 step)

;;; ---------- 派发 ----------

(define (step s cmd)
  (cond
    [(cmd-prefix? cmd) (session-set-prefix s (cmd-prefix-value cmd))]
    [(cmd-prefix-cancel? cmd) (session-set-prefix s #f)]
    [else
     (define s1 (session-set-prefix s #f))
     (or (for/or ([h (in-list (session-handlers s1))]) (h s1 cmd))
         (step-base s1 cmd))]))

(define (step-base s cmd)
  (cond
    [(cmd-focus? cmd)     (session-focus-move s (cmd-focus-dir cmd))]
    [(cmd-scroll? cmd)    (session-scroll s (cmd-scroll-n cmd))]
    [(cmd-nav? cmd)       (session-nav s (cmd-nav-dir cmd) (cmd-nav-extend? cmd))]
    [(cmd-toggle? cmd)    (session-toggle-slot s (cmd-toggle-slot cmd))]
    [(cmd-panel-swap? cmd) (session-panel-swap s)]
    [(cmd-resize? cmd)    (session-resize s (cmd-resize-w cmd) (cmd-resize-h cmd))]
    [(cmd-resize-view? cmd) (session-resize-view s (cmd-resize-view-axis cmd) (cmd-resize-view-delta cmd))]
    [(cmd-quit? cmd)      (session-quit s)]
    [(cmd-close? cmd)     (session-hide-focused s)]
    [(cmd-split? cmd)     (session-split-focused s (cmd-split-axis cmd))]
    [(cmd-insert? cmd)    (session-insert s (cmd-insert-text cmd))]
    [(cmd-delete? cmd)    (session-delete s)]
    [(cmd-backspace? cmd) (session-backspace s)]
    [(cmd-undo? cmd)      (session-undo s)]
    [(cmd-redo? cmd)      (session-redo s)]
    [(cmd-select-all? cmd) (session-select-all s)]
    [(cmd-copy? cmd)      (session-copy s)]
    [(cmd-cut? cmd)       (session-cut s)]
    [(cmd-paste? cmd)     (session-paste s)]
    [(cmd-prompt-submit? cmd) (session-prompt-submit s)]
    [(cmd-prompt-cancel? cmd) (session-prompt-cancel s)]
    [(cmd-mouse-press? cmd)  (session-mouse-press s (cmd-mouse-press-col cmd) (cmd-mouse-press-row cmd))]
    [(cmd-mouse-scroll? cmd) (session-mouse-scroll s (cmd-mouse-scroll-col cmd) (cmd-mouse-scroll-row cmd) (cmd-mouse-scroll-delta cmd))]
    [else s]))
