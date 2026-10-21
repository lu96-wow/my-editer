#lang racket

;;; edit-tui-rebuild/config/keymap/default.rkt —— 默认键位表（唯一来源）
;;;
;;; 所有 key-sequence -> command 的绑定都在这里：
;;;   cursor      光标移动：方向 / Home / End / 翻页
;;;   focus       焦点移动：C-x 方向
;;;   layout      布局拆分：C-w 方向
;;;   global      cursor + focus + layout（基础操作）
;;;   app         应用命令：filetree 显隐 / save / quit
;;;   edit        导航 + 插入 / 删除 / 历史（buffer 本地）
;;;   filetree    navigation + Enter / C-r
;;;   input       Esc/C-g Enter C-h/C-t 编辑/移动
;;;   placement   Enter/Esc/方向
;;;
;;; 命令实现仍在各插件 / app；这里只做键位配置。
;;; 选择键位 = require 本模块，把 default-keymap 放进 app-state；
;;; 或者复制本文件改绑定。

(require "../../core/command/api.rkt"
         "../../app/keymap.rkt"
         "../../edit/api.rkt"
         "../../filetree/api.rkt"
         "../../chrome/api.rkt"
         "../../app/commands.rkt"
         "../../app/placement.rkt")

(provide default-keymap
         cursor-command-table
         navigation-command-table   ; cursor 的兼容别名
         focus-command-table
         layout-command-table
         global-command-table
         app-command-table
         edit-command-table
         filetree-command-table
         filetree-panel-stack
         input-command-table
         input-command-stack
         placement-table)

;;; ════════════════ navigation / edit ════════════════

(define (nav-binding dir)
  (list (list (list (key dir)) (nav-command dir))
        (list (list (key dir 'shift)) (nav-command dir #:extend? #t))))

(define cursor-command-table
  (command-table-from-bindings
   (append
    (append* (for/list ([d (in-list '(left right up down home end))])
               (nav-binding d)))
    ;; C-a / C-e 行首行尾，C-f 逐字符
    (list (list (list (key 'a 'ctrl)) (nav-command 'home))
          (list (list (key 'e 'ctrl)) (nav-command 'end))
          (list (list (key 'f 'ctrl)) (nav-command 'right)))
    ;; 翻页
    (list (list (list (key 'pageup))   (scroll-command 'page-up))
          (list (list (key 'pagedown)) (scroll-command 'page-down))))))

(define navigation-command-table cursor-command-table)

(define edit-command-table
  (command-table-merge
   navigation-command-table
   (command-table-from-bindings
    (list
     ;; 插入 / 删除
     (list (list (key 'enter))     (insert-command "\n"))
     (list (list (key 'tab))       (insert-command "  "))
     (list (list (key 'backspace)) (edit-action-command 'backspace))
     (list (list (key 'delete))    (edit-action-command 'delete))
     (list (list (key 'k 'ctrl))   (edit-action-command 'kill-line))
     ;; 历史
     (list (list (key 'z 'ctrl)) (edit-action-command 'undo))
     (list (list (key 'y 'ctrl)) (edit-action-command 'redo))))))

;;; ════════════════ focus / layout ════════════════

(define focus-command-table
  (keys
   [(key 'x 'ctrl) (key 'left)  (focus-command 'left)]
   [(key 'x 'ctrl) (key 'right) (focus-command 'right)]
   [(key 'x 'ctrl) (key 'up)    (focus-command 'up)]
   [(key 'x 'ctrl) (key 'down)  (focus-command 'down)]))

(define layout-command-table
  (keys
   [(key 'w 'ctrl) (key 'left)  (split-command 'left)]
   [(key 'w 'ctrl) (key 'right) (split-command 'right)]
   [(key 'w 'ctrl) (key 'up)    (split-command 'up)]
   [(key 'w 'ctrl) (key 'down)  (split-command 'down)]
   [(key 'd 'ctrl)              close-editor-panel-command]))

;;; ════════════════ filetree ════════════════

(define filetree-command-table
  (command-table-merge
   navigation-command-table
   (keys
    [(key 'enter)   filetree-enter-command]
    [(key 'r 'ctrl) filetree-refresh-command])))

(define filetree-panel-stack
  (command-table-stack-from-tables (list filetree-command-table)))

;;; ════════════════ input ════════════════

(define input-command-table
  (keys
   [(key 'g 'ctrl)  input-cancel-current]
   [(key 'escape)   input-cancel-current]
   [(key 'enter)    input-submit]
   ;; 输入栏专属：head / tail（C-h 是独立 token，不是 Backspace）
   [(key 'h 'ctrl)  input-home]
   [(key 't 'ctrl)  input-end]
   [(key 'backspace) input-backspace]
   [(key 'delete)    input-delete]
   [(key 'left)      input-left]
   [(key 'b 'ctrl)   input-left]
   [(key 'right)     input-right]
   [(key 'f 'ctrl)   input-right]
   [(key 'home)      input-home]
   [(key 'a 'ctrl)   input-home]
   [(key 'end)       input-end]
   [(key 'e 'ctrl)   input-end]))

(define input-command-stack
  (command-table-stack-from-tables (list input-command-table)))

;;; ════════════════ placement ════════════════

(define placement-table
  (keys
   [(key 'enter)  placement-commit]
   [(key 'escape) placement-cancel]
   [(key 'left)   (placement-focus-command 'left)]
   [(key 'right)  (placement-focus-command 'right)]
   [(key 'up)     (placement-focus-command 'up)]
   [(key 'down)   (placement-focus-command 'down)]))

;;; ════════════════ global / app / default keymap ════════════════

;; 全局基础操作：光标移动 + 焦点移动 + 布局拆分
(define global-command-table
  (command-table-merge
   cursor-command-table
   focus-command-table
   layout-command-table))

;; 应用命令：不属于基础编辑操作，单独一张表，仍是全局 fallback
(define app-command-table
  (keys
   [(key 'b 'ctrl) toggle-filetree-command]
   [(key 's 'ctrl) save-command]
   [(key 'q 'ctrl) quit-command]))

(define default-keymap
  (keymap
   (command-table-stack-from-tables
    (list app-command-table global-command-table))
   input-command-stack
   placement-table))
