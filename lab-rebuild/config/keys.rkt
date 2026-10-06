#lang racket

;;; lab-rebuild/config/keys.rkt —— 基础键位表（纯数据）。
;;;
;;; 这里只有**框架自带**的键；功能自带的默认键由功能的 `binding` 贡献在组装期补进来
;;; （见 `kernel/table.rkt` 的 keybinding、app-init 的 folding）。
;;; 前缀键用**表名**引用（'focus/'move/'resize），运行时由 cmd-prefix 查 session.named。

(require "../kernel/binding.rkt" "../kernel/table.rkt")

(provide edit-table global-table readonly-table input-edit-table confirm-table
         focus-table move-table resize-table named-tables)

(define edit-table
  (kbd
   text-binding        'insert
   paste-binding       'insert
   (key 'enter)        'newline
   (key 'tab)          'tab
   (key 'backspace)    'backspace
   (key 'delete)       'delete
   (key 'left)         '(nav left #f)
   (key 'right)        '(nav right #f)
   (key 'up)           '(nav up #f)
   (key 'down)         '(nav down #f)
   (key 'home)         '(nav home #f)
   (key 'end)          '(nav end #f)
   (key 'left 'shift)  '(nav left #t)
   (key 'right 'shift) '(nav right #t)
   (key 'up 'shift)    '(nav up #t)
   (key 'down 'shift)  '(nav down #t)
   (key 'home 'shift)  '(nav home #t)
   (key 'end 'shift)   '(nav end #t)
   (key 'a 'ctrl)      'select-all
   (key 'c 'ctrl)      'copy
   (key 'x 'ctrl)      'cut
   (key 'v 'ctrl)      'paste
   (key 'z 'ctrl)      'undo
   (key 'y 'ctrl)      'redo))

;;; ---------- 前缀表 ----------

(define focus-table
  (kbd
   (key 'left)   '(focus left)
   (key 'right)  '(focus right)
   (key 'up)     '(focus up)
   (key 'down)   '(focus down)
   (key 'escape) 'noop))

(define move-table
  (kbd
   (key 'left)   '(pane-move left)
   (key 'right)  '(pane-move right)
   (key 'up)     '(pane-move up)
   (key 'down)   '(pane-move down)
   (key 'escape) 'noop))

(define resize-table
  (kbd
   (key 'left)   '(pane-resize left)
   (key 'right)  '(pane-resize right)
   (key 'up)     '(pane-resize up)
   (key 'down)   '(pane-resize down)
   (key 'escape) 'noop))

(define global-table
  (kbd
   (key 'o 'ctrl) 'find-file
   (key 'b 'ctrl) 'toggle-sidebar
   (key 's 'ctrl) 'save
   (key 'q 'ctrl) 'quit
   (key 'l 'ctrl) 'split-lr
   (key 'k 'ctrl) 'split-tb
   (key 'd 'ctrl) 'pane-close
   (key 'p 'ctrl) (list 'prefix "C-p" 'focus)
   (key 'm 'alt)  (list 'prefix "M-m" 'move 'pane-move)
   (key 's 'alt)  (list 'prefix "M-s" 'resize)
   (mouse 'press 'left '())   'mouse-press
   (mouse 'scroll 'up '())    '(mouse-scroll -1)
   (mouse 'scroll 'down '())  '(mouse-scroll 1)))

(define readonly-table
  (kbd
   text-binding     'noop
   paste-binding    'noop
   (key 'enter)     'noop
   (key 'tab)       'noop
   (key 'backspace) 'noop
   (key 'delete)    'noop))

;; prompt 的两种键表：输入型 / 确认型（模态层叠在 base 之上）
(define input-edit-table
  (kbd
   (key 'enter)  'prompt-commit
   (key 'escape) 'prompt-cancel
   (key 'tab)    'noop))

(define confirm-table
  (kbd
   text-binding  'prompt-answer
   (key 'escape) 'prompt-cancel))

;; 命名表：组装期的绑定贡献往这里补键；前缀键按名字引用。
(define (named-tables)
  (hash 'edit edit-table
        'global global-table
        'readonly readonly-table
        'input-edit input-edit-table
        'confirm confirm-table
        'focus focus-table
        'move move-table
        'resize resize-table))
