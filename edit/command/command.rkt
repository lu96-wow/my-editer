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
                  session-resize-view session-close-focused
                  session-insert session-delete session-backspace
                  session-undo session-redo
                  session-select-all session-copy session-cut session-paste
                  session-prompt-submit session-prompt-cancel
                  session-panel-swap session-handlers
                  session-mouse-press session-mouse-scroll
                  session-set-prefix))

;;; ---------- 基础命令 ----------

(struct cmd-focus (dir) #:transparent)      ; 焦点几何移动
(struct cmd-scroll (n) #:transparent)       ; 滚焦点视图 n 个视觉行
(struct cmd-nav (dir extend?) #:transparent); 文本光标移动
(struct cmd-toggle (slot) #:transparent)    ; 切换 bindings 里某个洞（叶）的显隐
(struct cmd-panel-swap () #:transparent)    ; 同位置状态窗口互换（Tab）
(struct cmd-quit () #:transparent)
(struct cmd-close () #:transparent)         ; 关闭焦点窗口（面板不关）
(struct cmd-resize (w h) #:transparent)

;; document 命令
(struct cmd-insert (text) #:transparent)
(struct cmd-delete () #:transparent)
(struct cmd-backspace () #:transparent)
(struct cmd-undo () #:transparent)
(struct cmd-redo () #:transparent)
(struct cmd-select-all () #:transparent)
(struct cmd-copy () #:transparent)
(struct cmd-cut () #:transparent)
(struct cmd-paste () #:transparent)

;; 输入行
(struct cmd-prompt-submit () #:transparent)
(struct cmd-prompt-cancel () #:transparent)

;; 日志面板开关（实现见 feature/log.rkt）
(struct cmd-log-toggle () #:transparent)

;; 改焦点视图尺寸（axis : 'width | 'height）
(struct cmd-resize-view (axis delta) #:transparent)

;; 前缀（多键序列）
(struct cmd-prefix (value) #:transparent)        ; value : prefix
(struct cmd-prefix-cancel () #:transparent)

;; 鼠标
(struct cmd-mouse-press (col row) #:transparent)
(struct cmd-mouse-scroll (col row delta) #:transparent)

(provide (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-nav)
         (struct-out cmd-toggle) (struct-out cmd-panel-swap)
         (struct-out cmd-quit) (struct-out cmd-resize) (struct-out cmd-close)
         (struct-out cmd-insert) (struct-out cmd-delete) (struct-out cmd-backspace)
         (struct-out cmd-undo) (struct-out cmd-redo)
         (struct-out cmd-select-all) (struct-out cmd-copy) (struct-out cmd-cut) (struct-out cmd-paste)
         (struct-out cmd-prompt-submit) (struct-out cmd-prompt-cancel)
         (struct-out cmd-log-toggle)
         (struct-out cmd-resize-view)
         (struct-out cmd-prefix) (struct-out cmd-prefix-cancel)
         (struct-out cmd-mouse-press) (struct-out cmd-mouse-scroll)
         step)

;;; ---------- 派发：前缀 / feature handler 链 / 基础命令 ----------

(define (step s cmd)
  (cond
    ;; 选中前缀：进入下一层键表（可嵌套）
    [(cmd-prefix? cmd) (session-set-prefix s (cmd-prefix-value cmd))]
    ;; 取消 / 未命中：清空前缀
    [(cmd-prefix-cancel? cmd) (session-set-prefix s #f)]
    ;; 其余命令：先清前缀，再走 handler 链 -> 基础命令
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
    [(cmd-close? cmd)     (session-close-focused s)]
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
