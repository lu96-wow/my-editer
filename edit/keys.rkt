#lang racket

;;; edit/keys.rkt —— 键表配置（纯数据）
;;;
;;; 分成几张可组合的键表，最后 merge 成 base-keys：
;;;     edit-keys    编辑区导航
;;;     global-keys  全局（退出 / 开关 dock）
;;; 特性/模态将来各自造一张，merge 或 push 进 session 的键表叠。

(require tui "binding.rkt" "keymap.rkt" "command.rkt")

(provide base-keys edit-keys global-keys)

(define edit-keys
  (kbd
   (key 'left)     (cmd-focus 'left)
   (key 'right)    (cmd-focus 'right)
   (key 'up)       (cmd-focus 'up)
   (key 'down)     (cmd-focus 'down)
   (key 'pageup)   (cmd-scroll -5)
   (key 'pagedown) (cmd-scroll  5)))

(define global-keys
  (kbd
   (key 'q 'ctrl) (cmd-quit)
   (key 'b 'ctrl) (cmd-toggle 'panel)
   ;; resize 需要事件里的尺寸 → spec 用过程
   resize-binding (lambda (ev) (cmd-resize (resize-event-cols ev) (resize-event-rows ev)))))

(define base-keys (keymap-merge (list edit-keys global-keys)))
