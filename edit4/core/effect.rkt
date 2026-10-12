#lang racket

;;; edit4/core/effect.rkt —— Effect ADT（一次性 IO，边缘解释）
;;;
;;; Effect 是数据；只在 runtime 边缘被解释。命令返回 (cons world (listof effect))。
;;; open/reload 会在边缘产生**新 World**（读文件/读目录），所以解释器返回 World。

(provide (struct-out quit-effect) (struct-out log-effect)
         (struct-out save-file) (struct-out open-file) (struct-out reload-tree))

(struct quit-effect () #:transparent)
(struct log-effect (msg) #:transparent)
(struct save-file (path text) #:transparent)
(struct open-file (path) #:transparent)
(struct reload-tree () #:transparent)
