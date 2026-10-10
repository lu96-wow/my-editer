#lang racket

;;; edit-rebuild/plugins/config/words.rkt —— 词高亮配色策略（纯数据）
;;;
;;; sequential : 追加式词表（同词同色、相邻少撞色；有状态，随 document 版本 fork）
;;; hash       : 按词名散列（无状态、跨文件 / 会话稳定；可能撞色）
;;;
;;; word-color-count 仅 hash 模式用（散列后取的桶数；主题再按色板长度取模）。

(provide word-coloring word-color-count)

(define word-coloring 'sequential)
(define word-color-count 10)
