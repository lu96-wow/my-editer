#lang racket

;;; edit4/core/effect.rkt —— Effect ADT（一次性 IO，边缘解释）
;;;
;;; Effect 是数据；只在 runtime 边缘被解释。命令返回 (cons world (listof effect))。
;;; open/reload 会在边缘产生**新 World**（读文件/读目录），所以解释器返回 World。
;;; make/delete 是文件系统写操作，错误在边缘转成 log。

(provide (struct-out quit-effect) (struct-out log-effect)
         (struct-out open-file) (struct-out save-file)
         (struct-out make-file) (struct-out make-dir) (struct-out delete-path)
         (struct-out reload-tree))

(struct quit-effect () #:transparent)
(struct log-effect (msg) #:transparent)
(struct open-file (path) #:transparent)
(struct save-file (path text) #:transparent)
(struct make-file (path) #:transparent)
(struct make-dir (path) #:transparent)
(struct delete-path (path) #:transparent)
(struct reload-tree () #:transparent)
