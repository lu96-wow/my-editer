#lang racket

;;; edit-rebuild/core/command/input.rkt —— 输入事件值（纯）
;;;
;;; 后端把终端事件解成 input（绑定键 + 载荷），交给引擎派发。
;;; 这里只有值，没有解析 / 派发逻辑（那已全在 core/dispatch.rkt 的引擎里）。

(provide (struct-out input))

(struct input (binding text cols rows col row) #:transparent)
;; binding   : 绑定键 | #f
;; text      : string | #f       文本 / 粘贴载荷
;; cols rows : integer | #f      resize 载荷
;; col row   : integer | #f      鼠标载荷（屏幕 0-based）
