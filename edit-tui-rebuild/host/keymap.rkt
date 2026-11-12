#lang racket

;;; edit-tui-rebuild/host/keymap.rkt —— host 内置命令值 + 分 scope 的键表
;;;
;;; 这里只定义 host 自己解释的命令值，以及各 scope 的 host 内置表：
;;;   navigation  编辑器 / panel 共用的光标移动
;;;   editor      编辑器专用：navigation + 插入 / 删除 / 历史
;;;   global      全局 fallback：save / quit
;;;
;;; 插件命令仍由 command/<scope> contribution 提供；host 按当前 focus
;;; 把这些表组合成 command-table-stack。

(require "../core/command/api.rkt")

(provide (struct-out insert-command)
         (struct-out delete-command)
         (struct-out move-command)
         (struct-out scroll-command)
         (struct-out undo-command)
         (struct-out redo-command)
         (struct-out kill-line-command)
         (struct-out save-command)
         (struct-out quit-command)
         navigation-command-table
         editor-base-command-table
         global-base-command-table)

(struct insert-command (text) #:transparent)
(struct delete-command (kind) #:transparent)   ; 'backspace | 'delete
(struct move-command (dir extend?) #:transparent)
(struct scroll-command (which) #:transparent)  ; 'page-up | 'page-down
(struct undo-command () #:transparent)
(struct redo-command () #:transparent)
(struct kill-line-command () #:transparent)
(struct save-command () #:transparent)
(struct quit-command () #:transparent)

(define (nav dir) (move-command dir #f))
(define (nav-shift dir) (move-command dir #t))

;; 编辑器 / filetree / resources / docs 共用导航。
(define navigation-command-table
  (keys
   [(key 'left)      (nav 'left)]
   [(key 'right)     (nav 'right)]
   [(key 'up)        (nav 'up)]
   [(key 'down)      (nav 'down)]
   [(key 'home)      (nav 'home)]
   [(key 'end)       (nav 'end)]
   [(key 'left 'shift)  (nav-shift 'left)]
   [(key 'right 'shift) (nav-shift 'right)]
   [(key 'up 'shift)    (nav-shift 'up)]
   [(key 'down 'shift)  (nav-shift 'down)]
   [(key 'home 'shift)  (nav-shift 'home)]
   [(key 'end 'shift)   (nav-shift 'end)]
   [(key 'a 'ctrl)   (nav 'home)]
   [(key 'e 'ctrl)   (nav 'end)]
   [(key 'f 'ctrl)   (nav 'right)]
   [(key 'pageup)    (scroll-command 'page-up)]
   [(key 'pagedown)  (scroll-command 'page-down)]))

;; 编辑器专属：导航 + 插入 / 删除 / 历史。
;; C-f 在 editor scope 里仍然是右移；filetree 可以在自己的 scope 覆盖成前缀。
(define editor-base-command-table
  (command-table-merge
   navigation-command-table
   (keys
    [(key 'backspace) (delete-command 'backspace)]
    [(key 'delete)    (delete-command 'delete)]
    [(key 'enter)     (insert-command "\n")]
    [(key 'tab)       (insert-command "  ")]
    [(key 'k 'ctrl)   (kill-line-command)]
    [(key 'z 'ctrl)   (undo-command)]
    [(key 'y 'ctrl)   (redo-command)])))

;; 全局 fallback：不属于某个 buffer / panel 的应用命令。
(define global-base-command-table
  (keys
   [(key 's 'ctrl)   (save-command)]
   [(key 'q 'ctrl)   (quit-command)]))
