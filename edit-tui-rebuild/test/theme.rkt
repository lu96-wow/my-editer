#lang racket

;;; theme 配置：小表 -> 扁平表，require 即安装。
(require rackunit
         "../main.rkt"
         "../config/theme/default.rkt")

(check-true (list? base-theme))
(check-true (list? frame-theme))
(check-true (list? chrome-theme))
(check-true (list? overlay-theme))
(check-equal? (length default-theme)
              (+ (length base-theme)
                 (length frame-theme)
                 (length chrome-theme)
                 (length overlay-theme)))

;; 扁平表元素都是 (name style)
(check-true (for/and ([e (in-list default-theme)])
              (and (list? e)
                   (= 2 (length e))
                   (symbol? (car e))
                   (style? (cadr e)))))

(displayln "edit-tui-rebuild/test/theme.rkt: ok")
