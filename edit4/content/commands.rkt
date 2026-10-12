#lang racket

;;; edit4/content/commands.rkt —— 内容插件的数据装配（命令 + 键表）
;;;
;;; 编辑 / 文件 / 文件树 / 文档管理 / 输入行 / 指针 / 区域命令分别在各模块；
;;; 这里合成命令集与默认键表。键表按作用域分：editor、各面板 (panel NAME)、
;;; 前缀 (prefix new)；保存 / 刷新树 / 退出 / 侧栏切换等 scope = always。

(provide content-commands content-keymap)

(require "../core/command.rkt" "../core/keymap.rkt"
         "edit.rkt" "files.rkt" "tree-cmds.rkt" "buffers-cmds.rkt"
         "prompt.rkt" "pointer.rkt" "region.rkt" "focus.rkt")

(define (merge-all regs)
  (for/fold ([r (make-command-registry)]) ([x (in-list regs)]) (command-registry-merge r x)))

(define content-commands
  (merge-all (list edit-commands file-commands tree-commands buffers-commands
                   prompt-commands region-commands focus-commands content-pointer-commands)))

(define content-keymap
  (list
   ;; ---- 输入行（焦点是 *input* 面板） ----
   (list '(text) '(panel "*input*") (cmd 'insert-event-text))
   (list '(key backspace) '(panel "*input*") (cmd 'delete-back))
   (list '(key delete) '(panel "*input*") (cmd 'delete))
   (list '(key left) '(panel "*input*") (cmd 'nav 'left))
   (list '(key right) '(panel "*input*") (cmd 'nav 'right))
   (list '(key home) '(panel "*input*") (cmd 'nav 'home))
   (list '(key end) '(panel "*input*") (cmd 'nav 'end))
   (list '(key enter) '(panel "*input*") (cmd 'prompt-submit))
   (list '(key escape) '(panel "*input*") (cmd 'prompt-cancel))
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
   (list '(key w ctrl) 'editor (cmd 'close-doc))
   ;; ---- 文件树（焦点是 *tree* 面板） ----
   (list '(key up) '(panel "*tree*") (cmd 'nav 'up))
   (list '(key down) '(panel "*tree*") (cmd 'nav 'down))
   (list '(key left) '(panel "*tree*") (cmd 'tree-parent))
   (list '(key right) '(panel "*tree*") (cmd 'tree-child))
   (list '(key enter) '(panel "*tree*") (cmd 'tree-enter))
   (list '(key backspace) '(panel "*tree*") (cmd 'tree-toggle-hidden))
   (list '(key d ctrl) '(panel "*tree*") (cmd 'tree-delete))
   (list '(key n ctrl) '(panel "*tree*") (cmd 'prefix 'new))
   ;; ---- 文档管理（焦点是 *buffers* 面板） ----
   (list '(key up) '(panel "*buffers*") (cmd 'nav 'up))
   (list '(key down) '(panel "*buffers*") (cmd 'nav 'down))
   (list '(key left) '(panel "*buffers*") (cmd 'buffers-collapse))
   (list '(key right) '(panel "*buffers*") (cmd 'buffers-expand))
   (list '(text " ") '(panel "*buffers*") (cmd 'buffers-toggle))
   (list '(text "n") '(panel "*buffers*") (cmd 'new-view))
   (list '(key enter) '(panel "*buffers*") (cmd 'buffers-enter))
   (list '(key d ctrl) '(panel "*buffers*") (cmd 'buffers-close-view))
   (list '(key delete) '(panel "*buffers*") (cmd 'buffers-close-doc))
   ;; ---- 前缀 new：f 新文件 / d 新目录 ----
   (list '(text "f") '(prefix new) (cmd 'tree-new-file))
   (list '(text "d") '(prefix new) (cmd 'tree-new-dir))
   (list '(key escape) '(prefix new) (cmd 'cancel))
   ;; ---- 全局 ----
   (list '(key q ctrl) 'always (cmd 'quit))
   (list '(key s alt) 'always (cmd 'save))
   (list '(key u ctrl) 'always (cmd 'tree-reload))
   (list '(key h ctrl) 'always (cmd 'tree-toggle-hidden))
   (list '(key b ctrl) 'always (cmd 'region-toggle 'sidebar))
   (list '(key l ctrl) 'always (cmd 'region-toggle 'log))
   (list '(key b alt) 'always (cmd 'region-cycle 'sidebar 1) (cmd 'region-focus 'sidebar))
   (list '(key t alt) 'always (cmd 'region-activate 'sidebar "*tree*") (cmd 'region-focus 'sidebar))
   (list '(key e alt) 'always (cmd 'focus-editor))))
