#lang racket

;;; edit-tui/editor/face-submit.rkt —— 插件提交后台 face 任务的窄接口
;;;
;;; editor 层不启动线程、不碰 channel。host 在进入 TUI 会话时把
;;; current-face-submit 参数化成一个 face worker 的入队函数；headless / 测试
;;; 没有设置时退化为同步执行。

(provide current-face-submit
         face-submit!)

(define current-face-submit (make-parameter #f))

(define (face-submit! key thunk)
  (define submit (current-face-submit))
  (if submit
      (submit key thunk)
      (thunk)))
