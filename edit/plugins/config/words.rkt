#lang racket

;;; edit-rebuild/plugins/config/words.rkt —— 词高亮配置（纯数据）
;;;
;;; 词的色 = djb2(词名) 对 word-color-count 取模，再由主题色板取模。
;;; word-color-count 越大越不容易撞色（色板上限仍以主题为准）。

(provide word-color-count)

(define word-color-count 10)
