#lang racket

;;; edit-tui-rebuild/editor/action.rkt —— editor 操作产生的 action（纯数据）
;;;
;;; action 只描述“宿主还需要做什么”，不在这里解释。
;;; 第一阶段只有 quit / flash 两种；以后 open/save/job 也走这里。

(provide (struct-out quit-action)
         (struct-out flash-action)
         (struct-out open-file-action)
         (struct-out close-buffer-action))

(struct quit-action () #:transparent)
(struct flash-action (message) #:transparent)
(struct open-file-action (path) #:transparent)
(struct close-buffer-action () #:transparent)
