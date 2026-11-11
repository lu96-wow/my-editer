#lang racket

;;; edit-tui-rebuild/host/keymap.rkt —— 命令值 + 默认键位
;;;
;;; 命令是纯数据；host 负责解释。插件以后可以通过 plugin.commands
;;; 贡献自己的绑定，而不是改这张表。

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
         default-command-table)

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

(define default-command-table
  (keys
   [(key 'backspace) (delete-command 'backspace)]
   [(key 'delete)    (delete-command 'delete)]
   [(key 'enter)     (insert-command "\n")]
   [(key 'tab)       (insert-command "  ")]
   [(key 'k 'ctrl)   (kill-line-command)]
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
   [(key 'pagedown)  (scroll-command 'page-down)]
   [(key 'z 'ctrl)   (undo-command)]
   [(key 'y 'ctrl)   (redo-command)]
   [(key 's 'ctrl)   (save-command)]
   [(key 'q 'ctrl)   (quit-command)]))
