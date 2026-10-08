#lang racket

;;; lab-rebuild/config/keys.rkt —— 基础键表（纯数据）。
;;;
;;; edit   : 主区编辑键
;;; global : 框架全局键（分屏 / 关窗格 / 开关 dock / 退出）
;;; base   : 两者合并，作为 session.keys

(require "../kernel/binding.rkt" "../kernel/table.rkt")

(provide edit-table global-table base-table dock-base)

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
   (key 'y 'ctrl)      'redo
   (key 'n 'ctrl)      'complete))

(define global-table
  (kbd
   (key 'q 'ctrl) 'quit
   (key 's 'ctrl) 'save
   (key 'o 'ctrl) 'find-file
   (key 'b 'ctrl) 'tree-toggle        ; 开关文件树 dock
   (key 'l 'ctrl) 'split-lr
   (key 'k 'ctrl) 'split-tb
   (key 'd 'ctrl) 'pane-close
   (key 'h 'alt)  '(focus-dir left)    ; 焦点方向（临时代替前缀层）
   (key 'j 'alt)  '(focus-dir down)
   (key 'k 'alt)  '(focus-dir up)
   (key 'l 'alt)  '(focus-dir right)
   (key 'b 'alt)  'buffers-toggle       ; 开关缓冲区 dock
   (key 'p 'ctrl) 'prefix-focus          ; 前缀：焦点方向
   (key 'm 'alt)  'prefix-move           ; 前缀：窗格对调
   (key 's 'alt)  'prefix-resize         ; 前缀：窗格缩放
   (key 't 'ctrl) 'translate-split        ; C-t 前缀：Up/Down 选拆分方向
   (key 't 'alt)  'translate-close
   (mouse 'press 'left '())   'mouse-press
   (mouse 'scroll 'up '())    '(mouse-scroll -1)
   (mouse 'scroll 'down '())  '(mouse-scroll 1)))

(define base-table (keytable-merge (list edit-table global-table)))

;; 所有「同侧 dock」共用的基础键：Tab = 轮换同侧 dock（通用机制，dock 自行合并）。
(define dock-base
  (kbd (key 'tab) '(dock-cycle left)))
