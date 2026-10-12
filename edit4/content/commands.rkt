#lang racket

;;; edit4/content/commands.rkt —— 内容插件的数据装配（命令 + 键表）
;;;
;;; 编辑命令在 edit.rkt，文件命令在 files.rkt；这里只合并成「内容插件」贡献的命令集，
;;; 并给出默认键表。真正的装配（base + 内容 + 装饰 → Environment）在 app.rkt。

(provide content-commands content-keymap)

(require "../core/command.rkt"
         "edit.rkt" "files.rkt")

(define content-commands (command-registry-merge edit-commands file-commands))

(define content-keymap
  (list (list '(text) 'always (cmd 'insert-event-text))
        (list '(key backspace) 'always (cmd 'delete-back))
        (list '(key delete) 'always (cmd 'delete))
        (list '(key left) 'always (cmd 'nav 'left))
        (list '(key right) 'always (cmd 'nav 'right))
        (list '(key up) 'always (cmd 'nav 'up))
        (list '(key down) 'always (cmd 'nav 'down))
        (list '(key home) 'always (cmd 'nav 'home))
        (list '(key end) 'always (cmd 'nav 'end))
        (list '(key a ctrl) 'always (cmd 'select-all))
        (list '(key z ctrl) 'always (cmd 'undo))
        (list '(key y ctrl) 'always (cmd 'redo))
        (list '(key s alt) 'always (cmd 'save))
        (list '(key u ctrl) 'always (cmd 'reload-tree))))
