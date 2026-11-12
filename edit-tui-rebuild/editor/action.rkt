#lang racket

;;; edit-tui-rebuild/editor/action.rkt —— editor 操作产生的 action（纯数据）
;;;
;;; action 只描述“宿主还需要做什么”，不在这里解释。
;;; action 是跨层 / 跨 owner 的唯一请求方式：host 解释它，owner 更新自己的状态。

(provide (struct-out quit-action)
         (struct-out flash-action)
         (struct-out open-file-action)
         (struct-out close-buffer-action)
         (struct-out show-docs-action)
         (struct-out filetree-create-action)
         (struct-out filetree-delete-action))

(struct quit-action () #:transparent)
(struct flash-action (message) #:transparent)
(struct open-file-action (path) #:transparent)
(struct close-buffer-action () #:transparent)
;; 跨插件请求：completion 只发 action，docs owner 自己更新 docs state。
(struct show-docs-action (name) #:transparent)
;; filetree 只发 action；host 负责 prompt / 文件 IO / 刷新。
(struct filetree-create-action (parent kind) #:transparent) ; kind = 'file | 'dir
(struct filetree-delete-action (path kind) #:transparent)   ; kind = 'file | 'dir
