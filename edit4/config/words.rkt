#lang racket

;;; edit4/config/words.rkt —— 同词着色配置（纯数据）
;;;
;;; 词的色 = djb2(词名) 对 word-color-count 取模，再由调色板 'word 取模。
;;; 与 edit1 的 plugins/config/words.rkt 一致：12 色对齐 tokyo-night 的 word 色板。

(provide word-color-count)

(define word-color-count 12)
