#lang racket

;;; edit4/core/base.rkt —— 基础命令集装配 + 基础键表 / 作用域
;;;
;;; 命令实现拆在 window.rkt（窗口/焦点/前缀/退出）与 pointer.rkt（指针/拖拽）；
;;; 这里只把两者合成注册表，并给出默认键表与作用域表。
;;; 这一组就是「基础插件」贡献的数据（见 plugin.rkt / app.rkt）。

(provide base-commands base-keymap base-scopes)

(require "command.rkt" "scope.rkt" "window.rkt" "pointer.rkt")

(define base-commands (command-registry-merge window-commands pointer-commands))

(define base-keymap
  (list (list '(key s ctrl) 'always (cmd 'prefix 'split))
        (list '(key escape) '(prefix split) (cmd 'cancel))
        (list '(key right) '(prefix split) (cmd 'split 'h 'after))
        (list '(key left)  '(prefix split) (cmd 'split 'h 'before))
        (list '(key down)  '(prefix split) (cmd 'split 'v 'after))
        (list '(key up)    '(prefix split) (cmd 'split 'v 'before))
        (list '(key d ctrl) 'always (cmd 'close))
        (list '(key n alt)  'always (cmd 'focus 'next))
        (list '(key p alt)  'always (cmd 'focus 'prev))
        (list '(key left alt)  'always (cmd 'focus 'left))
        (list '(key right alt) 'always (cmd 'focus 'right))
        (list '(key up alt)    'always (cmd 'focus 'up))
        (list '(key down alt)  'always (cmd 'focus 'down))
        (list '(cursor press)   'always (cmd 'pointer-press))
        (list '(cursor move)    'always (cmd 'pointer-move))
        (list '(cursor release) 'always (cmd 'pointer-release))
        (list '(cursor scroll)  'always (cmd 'pointer-scroll))))

;; always / (prefix …) 是内置的；这里只放可扩展的具名作用域。
(define base-scopes (make-scope-registry '()))
