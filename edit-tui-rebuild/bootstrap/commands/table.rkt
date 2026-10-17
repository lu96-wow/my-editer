#lang racket

;;; layer  : bootstrap/commands
;;; effect : 无（只是把 command-id 映射到命令值）
;;;
;;; 框架命令表。插件贡献自己的 `#:commands`，不在这里 fold —— 这样
;;; “默认命令”与“插件命令”在数据上就是分开的，插件可以整体禁用。

(provide default-command-table)

(require "../../../core/editor/ops.rkt"
         "edit.rkt"
         "view.rkt"
         "region.rkt"
         "focus.rkt"
         "document.rkt"
         "placement.rkt")

;;; ════════════════ 默认命令表 ════════════════

(define (default-command-table)
  (define base
    (hash 'quit         (request-quit-command)
        'request-quit (request-quit-command)
        'request-close-file (request-close-file-command)
        'nav-left     (nav-command 'left)
        'nav-right    (nav-command 'right)
        'nav-up       (nav-command 'up)
        'nav-down     (nav-command 'down)
        'nav-home     (nav-command 'home)
        'nav-end      (nav-command 'end)
        'insert-enter (insert-command "\n")
        'backspace    (edit-command (op-backspace))
        'delete       (edit-command (op-delete))
        'undo         (undo-command)
        'redo         (redo-command)
        'split-left   (split-view-command 'left)
        'split-right  (split-view-command 'right)
        'split-up     (split-view-command 'up)
        'split-down   (split-view-command 'down)
        'close-view   (close-view-command)
        'detach-view  (detach-view-command)
        'attach-detached (attach-detached-command)
        'switch-member (switch-member-command)
        'close-region (close-region-command)
        'new-document (new-document-command)
        'open-file    (open-file-prompt-command)
        'save-current (save-current-command)
        'close-file   (request-close-file-command)
        'input-submit (input-submit-command)
        'input-cancel (input-cancel-command)
        'place-commit (place-commit-command)
        'place-cancel (place-cancel-command)
        'place-at     (place-at-command)
        'focus-left   (focus-move-command 'left)
        'focus-right  (focus-move-command 'right)
        'focus-up     (focus-move-command 'up)
        'focus-down   (focus-move-command 'down)
        'pointer-press (pointer-press-command)
        'pointer-drag  (pointer-drag-command)))
  base)
