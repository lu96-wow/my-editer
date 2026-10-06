#lang racket

(require "../platform/input.rkt"
         "../platform/keymap.rkt")

;;; lab-rebuild/config/keys.rkt —— 平台默认键位表（纯数据：binding → 命令描述）
;;;
;;; 命令描述 = 命令名（符号）或 (命令名 . 参数)，由 platform/command 解释。
;;; 本文件**不认识 core / actions / state**：改键位只改这里，不动行为代码。
;;;
;;; 键表以**命名 keymap** 注册进 platform/keymap 的 registry：
;;;   edit / global / readonly        文档命令集用
;;;   focus                           C-p 前缀表（匿名传给 prefix 也行）
;;;   pane-move / pane-resize         M-m / M-s 前缀表（窗格移动 / 大小）
;;;   input-edit / confirm            prompt 模态用（mode.rkt 按名字取）
;;; 功能包（文件树 / 补全 …）可以 keymap-add! 往这些表补键，或注册自己的模式键表。

(provide edit-keys focus-keys app-keys readonly-keys
         move-keys resize-keys
         input-edit-keys confirm-keys)

;;; ---------- 编辑 ----------

(define edit-keys
  (keymap-define 'edit
   text-binding         'insert
   paste-binding        'paste-text
   (key 'enter)         'newline-and-indent
   (key 'tab)           '(insert-string "  ")      ; 普通输入 Tab = 两个空格
   (key 'backspace)     'backspace
   (key 'delete)        'delete
   (key 'left)          '(nav left #f)
   (key 'right)         '(nav right #f)
   (key 'up)            '(nav up #f)
   (key 'down)          '(nav down #f)
   (key 'home)          '(nav home #f)
   (key 'end)           '(nav end #f)
   (key 'left 'shift)   '(nav left #t)
   (key 'right 'shift)  '(nav right #t)
   (key 'up 'shift)     '(nav up #t)
   (key 'down 'shift)   '(nav down #t)
   (key 'home 'shift)   '(nav home #t)
   (key 'end 'shift)    '(nav end #t)
   (key 'a 'ctrl)       'select-all
   (key 'c 'ctrl)       'copy
   (key 'x 'ctrl)       'cut
   (key 'v 'ctrl)       'paste
   (key 'z 'ctrl)       'undo
   (key 'y 'ctrl)       'redo))

;;; ---------- 焦点移动（C-p 前缀表） ----------

(define focus-keys
  (keymap-define 'focus
   (key 'left)   '(focus left)
   (key 'right)  '(focus right)
   (key 'up)     '(focus up)
   (key 'down)   '(focus down)
   (key 'escape) 'noop))

;;; ---------- 窗格移动 / 调整大小（前缀表） ----------

(define move-keys
  (keymap-define 'pane-move
   (key 'up)    '(pane-move up)
   (key 'down)  '(pane-move down)
   (key 'left)  '(pane-move left)
   (key 'right) '(pane-move right)
   (key 'escape) 'noop))

(define resize-keys
  (keymap-define 'pane-resize
   (key 'up)    '(pane-resize up)
   (key 'down)  '(pane-resize down)
   (key 'left)  '(pane-resize left)
   (key 'right) '(pane-resize right)
   (key 'escape) 'noop))

;;; ---------- 全局 ----------

(define app-keys
  (keymap-define 'global
   (key 'q 'ctrl) 'quit
   (key 's 'ctrl) 'save
   (key 'b 'ctrl) 'toggle-sidebar
   (key 'p 'ctrl) (list 'prefix "C-p" (list focus-keys))
   (key 'k 'ctrl) 'split-tb
   (key 'l 'ctrl) 'split-lr
   (key 'd 'ctrl) 'pane-close
   ;; 移动窗格：M-m（Alt+m）+ 方向键，或在 M-m 前缀下鼠标点击目标窗格。
   (key 'm 'alt)  (list 'prefix "M-m" (list move-keys) 'pane-move)
   ;; 调整窗格大小：M-s（Alt+s）+ 方向键。
   (key 's 'alt)  (list 'prefix "M-s" (list resize-keys))))

;;; ---------- 只读基表 ----------

(define readonly-keys
  (keymap-define 'readonly
   text-binding     'noop
   paste-binding    'noop
   (key 'enter)     'noop
   (key 'tab)       'noop
   (key 'backspace) 'noop
   (key 'delete)    'noop
   (key 'v 'ctrl)   'noop
   (key 'x 'ctrl)   'noop
   (key 'z 'ctrl)   'noop
   (key 'y 'ctrl)   'noop))

;;; ---------- 模态 ----------

(define input-edit-keys
  (keymap-define 'input-edit
   (key 'enter)  'commit
   (key 'escape) 'cancel
   (key 'tab)    'noop))

(define confirm-keys
  (begin
    (keymap-merge-into! (keymap-define 'confirm) readonly-keys)
    (keymap-define 'confirm
     text-binding  'answer
     (key 'escape) 'cancel)))
