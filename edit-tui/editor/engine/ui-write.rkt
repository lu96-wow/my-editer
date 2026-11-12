#lang racket

;;; edit-tui/editor/engine/ui-write.rkt —— UI 投影写能力
;;;
;;; 给 status / filetree / input / completion / docs 写回普通 view。
;;; 这不是用户文本编辑入口。

(require "ui-projection.rkt")

(provide engine-set-view-content!
         engine-set-view-cursor!
         engine-set-view-face-track!
         engine-set-view-face-lines!
         engine-set-view-lines!)
