#lang racket

;;; edit-rebuild/core/test/theme-test.rkt —— 主题按 config 的 active-scheme 组装（headless）
;;;
;;;   raco test edit-rebuild/core/test/theme-test.rkt

(require rackunit
         "../theme/theme.rkt"
         "../theme/scheme.rkt"
         "../theme/style.rkt"
         "../config/theme.rkt"
         "../face/face.rkt")

;; 主题的调色板 == 选中的方案（首个 keyword 组 / 首层括号底）
(check-equal? (style-fg (theme-style default-theme (palette-color 'keyword 0)))
              (vector-ref (scheme-keyword active-scheme) 0))
(check-equal? (style-bg (theme-style default-theme (palette-bg 'bracket 0)))
              (vector-ref (scheme-bracket active-scheme) 0))
;; 缺失 face → 正文色
(check-equal? (style-fg (theme-style default-theme (quote no-such-face)))
              (scheme-fg active-scheme))
