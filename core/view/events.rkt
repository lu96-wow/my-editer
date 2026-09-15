#lang racket

;;; events.rkt —— 后端无关的输入事件
;;;
;;; 后端（tui/gui/web）把原始输入翻译成 ui-event，事件层（app/event.rkt）
;;; 消费 ui-event。换后端时，这个结构完全不变。

(provide (struct-out ui-event))

(struct ui-event (kind data) #:transparent)
;; data : list，各 kind 的含义：
;;   'insert-string  (string)                插入文本
;;   'move-up 'move-down 'move-left 'move-right  ()
;;   'backspace 'delete 'newline  ()
;;   'home 'end  ()
;;   'pageup 'pagedown  ()
;;   'ctrl-char      (char)                  Ctrl+字母
;;   'resize         (rows cols)             窗口尺寸
;;   'mouse-press    (button x y mods)       x/y 0-based 显示坐标
;;   'mouse-scroll   (dir x y mods)          dir ∈ 'up/'down
;;   'quit           ()
