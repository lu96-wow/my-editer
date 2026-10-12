#lang racket

;;; edit4/core/effect.rkt —— Effect ADT（一次性 IO，边缘解释）
;;;
;;; Effect 是数据；只在 runtime 边缘被解释。命令返回 (cons world (listof effect))。

(provide (struct-out quit-effect) (struct-out log-effect) (struct-out save-file))

(struct quit-effect () #:transparent)
(struct log-effect (msg) #:transparent)
(struct save-file (path text) #:transparent)
