#lang racket

;;; state-data.rkt —— buffer / view 的可变数据定义（core 内部）
;;;
;;; 只有 core 内部模块（state.rkt / ops.rkt）require 本模块。
;;; 对外一律经 state.rkt 暴露「访问器 + 提交壳」，**不暴露裸 setter**
;;; （set-buffer-*! / set-view-*!），保证写回 buffer/view 只有一条路径。
;;;
;;; 为什么单独拆出来：Racket 的 struct-out 会把 mutable 字段的 setter 一起导出，
;;; 若 struct 定义在 state.rkt，set-view-selections! 就会和提交壳 view-set-selections!
;;; 一起往外漏（名字还只差词序，极易误用）。把定义放这里，state.rkt 用 except-out
;;; 裁掉 setter 再导出。

(provide (struct-out buffer)
         (struct-out view))

;; 共享单元：一份内容 + 历史 + 它的所有 view。身份 = 对象本身。
(struct buffer (name history views) #:mutable)
;; name    : string
;; history : history        （current 就是当前 document 真身）
;; views   : (listof view)  共享这份内容的视图

;; 视图：显示状态，指回 buffer。身份 = 对象本身。
(struct view (buffer viewport selections) #:mutable)
