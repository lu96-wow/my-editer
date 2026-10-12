#lang racket

;;; edit4/content/commands.rkt —— 内容插件的数据装配（命令 + 键表）
;;;
;;; 编辑命令在 edit.rkt，文件命令在 files.rkt，文件树命令在 tree-cmds.rkt；
;;; 这里只合成「内容插件」的命令集与默认键表。真正的装配在 app.rkt。
;;;
;;; 键表按作用域分：编辑器按键 scope = editor；文件树按键 scope = (panel "*tree*")；
;;; 保存 / 刷新树等全局键 scope = always。作用域实现见 content/scopes.rkt。

(provide content-commands content-keymap)

(require "../core/command.rkt" "../core/keymap.rkt"
         "edit.rkt" "files.rkt" "tree-cmds.rkt")

(define content-commands
  (command-registry-merge
   edit-commands
   (command-registry-merge file-commands tree-commands)))

(define content-keymap
  (list
   ;; ---- 编辑（焦点是可编辑文档） ----
   (list '(text) 'editor (cmd 'insert-event-text))
   (list '(key enter) 'editor (cmd 'insert-text "\n"))
   (list '(key backspace) 'editor (cmd 'delete-back))
   (list '(key delete) 'editor (cmd 'delete))
   (list '(key left) 'editor (cmd 'nav 'left))
   (list '(key right) 'editor (cmd 'nav 'right))
   (list '(key up) 'editor (cmd 'nav 'up))
   (list '(key down) 'editor (cmd 'nav 'down))
   (list '(key home) 'editor (cmd 'nav 'home))
   (list '(key end) 'editor (cmd 'nav 'end))
   (list '(key a ctrl) 'editor (cmd 'select-all))
   (list '(key c ctrl) 'editor (cmd 'copy))
   (list '(key x ctrl) 'editor (cmd 'cut))
   (list '(key v ctrl) 'editor (cmd 'paste))
   (list '(key z ctrl) 'editor (cmd 'undo))
   (list '(key y ctrl) 'editor (cmd 'redo))
   ;; ---- 文件树（焦点是 *tree* 面板） ----
   (list '(key up) '(panel "*tree*") (cmd 'nav 'up))
   (list '(key down) '(panel "*tree*") (cmd 'nav 'down))
   (list '(key left) '(panel "*tree*") (cmd 'tree-parent))
   (list '(key right) '(panel "*tree*") (cmd 'tree-child))
   (list '(key enter) '(panel "*tree*") (cmd 'tree-enter))
   (list '(key backspace) '(panel "*tree*") (cmd 'tree-toggle-hidden))
   ;; ---- 全局 ----
   (list '(key s alt) 'always (cmd 'save))
   (list '(key u ctrl) 'always (cmd 'tree-reload))
   (list '(key h ctrl) 'always (cmd 'tree-toggle-hidden))))
