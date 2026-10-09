#lang racket

;;; edit/keys.rkt —— 全局键表 + 组合（纯数据）
;;;
;;;   tables.rkt    编辑命令表（edit-keys）等可挂 document 的键表
;;;   global-keys   全局（退出 / 开关侧栏 / 状态窗口互换 / 文件 / resize / 鼠标）
;;;   base-keys     = merge(edit-keys, global-keys)
;;;
;;; 状态窗口自带键表（panel keys）优先于 document / global。

(require tui "binding.rkt" "../core/keymap.rkt" "command.rkt"
         "tables.rkt" "../document/document.rkt")

(provide base-keys global-keys
         (all-from-out "tables.rkt"))

(define global-keys
  (kbd
   (key 'q 'ctrl) (cmd-quit)
   (key 'b 'ctrl) (cmd-toggle 'side)
   (key 'tab)     (cmd-panel-swap)
   (key 's 'ctrl) (cmd-save)
   (key 'f 'ctrl) (cmd-open-file)
   ;; resize 需要事件里的尺寸 → spec 用过程
   resize-binding (lambda (ev) (cmd-resize (resize-event-cols ev) (resize-event-rows ev)))
   ;; 鼠标：点击 = 聚焦 + 定位；滚轮 = 滚动光标所在视图
   (mouse 'press 'left '())  (lambda (ev) (cmd-mouse-press (mouse-col ev) (mouse-row ev)))
   (mouse 'scroll 'up '())   (lambda (ev) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev) -1))
   (mouse 'scroll 'down '()) (lambda (ev) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev)  1))))

(define base-keys (keymap-merge (list edit-keys global-keys)))
