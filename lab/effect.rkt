#lang racket

;;; lab/effect.rkt —— 抽象副作用（纯值，后端解释）
;;;
;;; 命令层不直接做 io，只返回 effect 列表；由后端执行。'redraw 只是个符号。

(provide
 (struct-out quit)
 (struct-out io-load)
 (struct-out io-save)
 redraw)

;; 退出应用。
(struct quit () #:transparent)

;; 从磁盘读文件到新文档（后端执行后把结果喂回命令层）。
(struct io-load (path) #:transparent)

;; 把某文档写回磁盘（后端执行）。
(struct io-save (path did) #:transparent)

;; 重绘。纯符号，放在 effect 列表里。
(define redraw 'redraw)
