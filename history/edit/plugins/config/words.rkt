#lang racket

;;; edit-rebuild/plugins/config/words.rkt —— 词高亮配置（纯数据）
;;;
;;; 词的色 = djb2(词名) 对 word-color-count 取模，再由主题色板取模。
;;; word-color-count 越大越不容易撞色；这里与 tokyo-night 的 word 色板长度（12）对齐，
;;; 12 色全部用上、分布均匀。换主题时若色板长度不同，palette-ref 会自动取模，不会越界。

(provide word-color-count)

(define word-color-count 12)
