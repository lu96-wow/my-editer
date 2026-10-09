#lang racket

;;; edit/plugin/registry.rkt —— document 插件协议 + 按文档筛选（纯）
;;;
;;; document 插件 = 「是否适用」谓词 + 一个从文本算 fills 的纯函数：
;;;   applies? : path text       -> boolean          该文档是否启用本插件
;;;   fills    : text path       -> (listof fill)    全量（本版不做增量）
;;;   fill     = (list l0 c0 l1 c1 face)             半开区间
;;; face = symbol | palette-color | face-stack（见 core/face.rkt）。
;;;
;;; 插件不改文本、不持有状态 —— 所以 fills 是 (文本, 插件) 的纯函数；
;;; 「结果何时写回、缓存多久」交给 session 的渲染前步骤（按文档 handle 判新旧）。
;;;
;;; **应用顺序 = 目录顺序**：多个插件写同一格时不去掉谁，而是按顺序 face-compose 成
;;; face-stack；主题逐分量合并，于是「括号背景」和「语法前景」可以共存。

(provide (struct-out doc-plugin) plugins-for)

(struct doc-plugin (name applies? fills) #:transparent)

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((doc-plugin-applies? p) path text))
    p))
