#lang racket

;;; events.rkt —— 后端无关的类型化输入事件（参考 racket/gui 事件模型）
;;;
;;; 设计（对照 racket/gui）：
;;;   - 事件是类型化 struct（非 (kind data)），按结构谓词分派
;;;   - 修饰键独立为布尔（control/alt/shift/meta）
;;;   - key-event（物理键/键位）与 text-event（翻译后文本）分离，
;;;     解决「Ctrl+B 分屏 vs 输入 b」的歧义；IME/粘贴统一走 text-event
;;;   - 每类事件对应一个命令槽（on-*），框架按运行时类型路由
;;;   - 坐标 0-based 屏幕坐标（后端在边界转换）

(provide
 (struct-out modifiers)
 (struct-out text-event)
 (struct-out key-event)
 (struct-out mouse-press-event)
 (struct-out mouse-wheel-event)
 (struct-out resize-event)
 (struct-out quit-event))

(struct modifiers (control alt shift meta) #:transparent)

;; 文本（已解码，含 IME / 粘贴的多字符）→ 交给 on-text 插入
(struct text-event (text modifiers) #:transparent)

;; 物理键 → 键位绑定
;; key ∈ char（可打印键 + 修饰键，如 control + #\b）
;;     | symbol（'up 'down 'left 'right 'home 'end 'pageup 'pagedown
;;              'backspace 'delete 'enter 'tab 'escape 'f1 .. 'f12）
(struct key-event (key modifiers) #:transparent)

;; 鼠标（x/y 0-based 屏幕坐标）
(struct mouse-press-event (button x y modifiers) #:transparent)
(struct mouse-wheel-event (direction x y modifiers) #:transparent)

;; 尺寸（buffer 区）
(struct resize-event (rows cols) #:transparent)

;; 控制
(struct quit-event () #:transparent)
