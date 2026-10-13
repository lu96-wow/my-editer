#lang racket

;;; edit4/core/event.rkt —— 输入事件（数据）
;;;
;;; 命令层只把事件用于两件事：匹配 binding、提供 Ctx 数据。
;;; 事件本身不携带任何「命令」知识。

(provide (struct-out key-event) (struct-out text-event)
         (struct-out cursor-event) (struct-out resize-event)
         (struct-out job-event))

(struct key-event (key mods) #:transparent)        ; mods : (listof symbol)
(struct text-event (text) #:transparent)           ; 直接输入的文本
(struct cursor-event (kind button x y) #:transparent) ; kind = press|release|move|scroll
(struct resize-event (w h) #:transparent)
(struct job-event (id kind result tag) #:transparent) ; 后台结果回注（tag 原样带回）
