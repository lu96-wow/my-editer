#lang racket

;;; lab/base/face.rkt —— 需要带参数的 face 值（动态 face）
;;;
;;; core 的 face 是不透明值（core 不解释），由主题负责解释。
;;; 普通 face 用 symbol；需要参数（如括号按深度）时用这里的结构体。
;;;
;;; ⚠ 用 struct（#:prefab）而不是 pair / list：
;;;   1) 渲染补丁用 (overlay . face) 编码，后端靠 pair? 区分 overlay 和 face，
;;;      pair 形状的 face 会被误当成 overlay；
;;;   2) #:prefab 可跨 place / 进程序列化（插件后台进程要把 face 传回来）。

(provide (struct-out bracket-depth))

;; 括号按嵌套深度上背景色；具体颜色由主题按 n 取模决定（深度无上限）。
(struct bracket-depth (n) #:prefab)
