#lang racket

;;; edit-rebuild/core/command/tables.rkt —— 编辑命令表（纯数据）
;;;
;;; 编辑命令表 = core 编辑命令 ⊕ 焦点命令（两张可组合的键表 merge）：
;;;     edit-command-keys   插入 / 删除 / 光标移动 / 选区 / 剪贴板 / 撤销重做
;;;     focus-keys          视图间焦点移动（Alt+方向 / C-p 前缀）
;;;     resize-prefix       C-o 前缀：改焦点视图尺寸
;;;     edit-keys           = merge(edit-command-keys, focus-keys)   ← 编辑命令表（默认 doc 表）
;;;
;;; 与「全局键」（global/base，见 keys.rkt）分开：编辑命令表可挂到 document 上。

(require "../keymap.rkt" "key.rkt" "command.rkt")

(provide edit-command-keys focus-keys focus-prefix resize-prefix split-prefix edit-keys)

;;; ---------- core 编辑命令（方向键 = 光标） ----------

(define edit-command-keys
  (kbd
   ;; 文本输入
   text-binding     text-spec
   (key 'enter)     (cmd-insert "\n")
   (key 'backspace) (cmd-backspace)
   (key 'delete)    (cmd-delete)
   ;; 光标移动
   (key 'left)      (cmd-nav 'left #f)
   (key 'right)     (cmd-nav 'right #f)
   (key 'up)        (cmd-nav 'up #f)
   (key 'down)      (cmd-nav 'down #f)
   (key 'home)      (cmd-nav 'home #f)
   (key 'end)       (cmd-nav 'end #f)
   ;; 选区 / 剪贴板
   (key 'a 'ctrl)   (cmd-select-all)
   (key 'c 'ctrl)   (cmd-copy)
   (key 'x 'ctrl)   (cmd-cut)
   (key 'v 'ctrl)   (cmd-paste)
   ;; 历史
   (key 'z 'ctrl)   (cmd-undo)
   (key 'y 'ctrl)   (cmd-redo)
   ;; 补全（M-/） / 光标处文档（M-d）
   (key '/ 'alt)    (cmd-complete)
   (key 'd 'alt)    (cmd-docs-show)))

;;; ---------- 焦点前缀（C-p 后接方向） ----------

(define focus-prefix
  (kbd
   (key 'up)     (cmd-focus 'up)
   (key 'down)   (cmd-focus 'down)
   (key 'left)   (cmd-focus 'left)
   (key 'right)  (cmd-focus 'right)
   (key 'escape) (cmd-prefix-cancel)))

;;; ---------- 尺寸前缀（C-o 后接方向） ----------

(define resize-prefix
  (kbd
   (key 'left)   (cmd-resize-view 'width  -1)
   (key 'right)  (cmd-resize-view 'width   1)
   (key 'up)     (cmd-resize-view 'height -1)
   (key 'down)   (cmd-resize-view 'height  1)
   (key 'escape) (cmd-prefix-cancel)))

;;; ---------- 分裂前缀（C-s 后接 - / \\） ----------
;;;   -  水平分隔（上下）   \  垂直分隔（左右）

(define split-prefix
  (kbd
   (key '-)      (cmd-split 'tb)
   (key '|\|)    (cmd-split 'lr)
   (key 'escape) (cmd-prefix-cancel)))

;;; ---------- 焦点命令 ----------

(define focus-keys
  (kbd
   (key 'left 'alt)  (cmd-focus 'left)
   (key 'right 'alt) (cmd-focus 'right)
   (key 'up 'alt)    (cmd-focus 'up)
   (key 'down 'alt)  (cmd-focus 'down)
   (key 'p 'ctrl)    (prefix "C-p" focus-prefix)
   (key 'o 'ctrl)    (prefix "C-o" resize-prefix)
   (key 's 'ctrl)    (prefix "C-s" split-prefix)))

;;; ---------- 编辑命令表 = 编辑 ⊕ 焦点 ----------

(define edit-keys (keymap-merge (list edit-command-keys focus-keys)))
