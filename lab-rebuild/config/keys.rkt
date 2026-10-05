#lang racket

(require "../base/input.rkt"
         "../command/table.rkt")

;;; lab-rebuild/config/keys.rkt —— 默认键位表（纯数据：binding → 命令描述）
;;;
;;; 命令描述 = 命令名（符号）或 (命令名 . 参数)，由 command/registry 解释。
;;; 本文件**不认识 core / actions / state**：改键位只改这里，不动行为代码。
;;;
;;; 表的用途（由 command/dispatch 按 did / 模态选）：
;;;   edit-keys        编辑文档
;;;   focus-keys       C-p 前缀下的焦点移动
;;;   app-keys         全局（对所有文档生效）
;;;   readonly-keys    只读基表（吞编辑键），文件树 / 文档列表 / 确认模态叠在它上
;;;   tree-keys        文件树面板
;;;   bufs-keys        文档 / 视图列表面板
;;;   input-edit-keys  输入型模态（回车提交 / Esc 取消）
;;;   confirm-keys     确认型模态（y / n）

(provide edit-keys focus-keys app-keys readonly-keys tree-keys bufs-keys
         input-edit-keys confirm-keys)

;;; ---------- 编辑 ----------

(define edit-keys
  (command-table
   text-binding         'insert
   paste-binding        'paste-text
   (key 'enter)         '(insert-string "\n")
   (key 'tab)           '(insert-string "\t")
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

;;; ---------- 焦点移动（C-p 前缀下的默认表） ----------
;;; 终端里 Ctrl+↑/↓ 常被吞（VTE 直接丢），所以用前缀键：
;;;   C-p 然后 left/right/up/down → 移焦点
;;; C-p 是普通控制字节 0x10，方向键无修饰，任何终端都送得到。

(define focus-keys
  (command-table
   (key 'left)   '(focus left)
   (key 'right)  '(focus right)
   (key 'up)     '(focus up)
   (key 'down)   '(focus down)
   (key 'escape) 'noop))     ; 退出前缀（app 会自动清）

;;; ---------- 全局 ----------

(define app-keys
  (command-table
   (key 'q 'ctrl) 'quit
   (key 'o 'ctrl) 'toggle-focus
   (key 'p 'ctrl) (list 'prefix "C-p" (list focus-keys))   ; 前缀：移焦点
   (key 's 'ctrl) 'save
   ;; 编辑区分屏：K 水平（上下）/ L 垂直（左右）分隔，D 关窗格
   (key 'k 'ctrl) 'split-tb
   (key 'l 'ctrl) 'split-lr
   (key 'd 'ctrl) 'pane-close))

;;; ---------- 只读基表 ----------

(define readonly-keys
  (command-table
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

;;; ---------- 文件树 ----------

(define tree-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       'toggle-left
          (key 'enter)     'tree-activate
          (key 'n 'ctrl)   'tree-new-file
          (key 'l 'ctrl)   'tree-new-dir
          (key 'backspace) 'tree-delete))))

;;; ---------- 文档 / 视图列表 ----------

(define bufs-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       'toggle-left
          (key 'enter)     'bufs-activate
          (key 'n 'ctrl)   'bufs-new-view
          (key 'backspace) 'bufs-close))))

;;; ---------- 模态 ----------
;;; input-edit-keys  输入型：enter 提交、escape 取消、tab 吞掉；
;;;                  字符 / 退格落全局 edit-keys（本表不绑 → 回落）。
;;; confirm-keys     确认型：y / n 收 bool，其余吞掉。

(define input-edit-keys
  (command-table
   (key 'enter)  'commit
   (key 'escape) 'cancel
   (key 'tab)    'noop))

(define confirm-keys
  (command-merge
   (list readonly-keys
         (command-table
          text-binding  'answer
          (key 'escape) 'cancel))))
