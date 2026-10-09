#lang racket

;;; edit/keys.rkt —— 全局键表 + 组合（纯数据）
;;;
;;;   tables.rkt    编辑命令表（edit-keys）等可挂 document 的键表
;;;   global-keys   全局（退出 / 开关侧栏 / 状态窗口互换 / 文件 / resize / 鼠标）
;;;   base-keys     = merge(edit-keys, global-keys)
;;;
;;; 状态窗口自带键表（panel keys）优先于 document / global。

(require "key.rkt" "../core/keymap.rkt" "command.rkt"
         "tables.rkt")

(provide base-keys global-keys
         (all-from-out "tables.rkt"))

(define global-keys
  (kbd
   (key 'q 'ctrl) (cmd-quit)
   (key 'd 'ctrl) (cmd-close)
   (key 'b 'ctrl) (cmd-toggle 'side)
   (key 'l 'ctrl) (cmd-log-toggle)
   (key 'tab)     (cmd-panel-swap)
   ;; 文件命令（cmd-save / cmd-open-file）由 document 层自带 document-keys，assembly 合并
   ;; 事件取数据的 spec 标记（真正取数据在后端）；键表配置不 require tui
   resize-binding resize-spec
   (mouse 'press 'left '())  mouse-press-spec
   (mouse 'scroll 'up '())   mouse-scroll-up-spec
   (mouse 'scroll 'down '()) mouse-scroll-down-spec))

(define base-keys (keymap-merge (list edit-keys global-keys)))
