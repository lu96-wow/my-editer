#lang racket

;;; lab-rebuild/smoke-theme.rkt —— 主题槽位覆盖 + 固定颜色表回归
;;;
;;; 守住「能定义颜色的地方」：两个主题必须覆盖 slots.rkt 里的全部槽位，
;;; 且每处颜色都是合法的 #f 或 (r g b)，色板非空。

(require rackunit
         racket/list
         "config/theme/main.rkt")

(define themes (list dark-theme light-theme))

;; 两个主题都必须覆盖所有槽位（face / palette / overlay）
(for ([t (in-list themes)])
  (check-equal? (theme-missing-slots t) '()))

;; 槽位清单非空且无重复
(check-true (> (length static-face-slots) 0))
(check-true (> (length palette-slots) 0))
(check-true (> (length overlay-slots) 0))
(check-equal? (length static-face-slots) (length (remove-duplicates static-face-slots)))
(check-equal? (length palette-slots) (length (remove-duplicates palette-slots)))

(define (valid-dim? x)
  (or (not x) (and (list? x) (= 3 (length x)) (andmap exact-nonnegative-integer? x))))

;; 每个 face 解析出的 (fg bg) 都合法
(for ([t (in-list themes)])
  (for ([s (in-list static-face-slots)])
    (define-values (fg bg) (theme-face-colors t s))
    (check-true (valid-dim? fg))
    (check-true (valid-dim? bg))))

;; 每个色板非空、每项合法；(fg bg) 至少设了一维
(for ([t (in-list themes)])
  (for ([k (in-list palette-slots)])
    (define v (hash-ref (theme-palettes t) k))
    (check-true (> (vector-length v) 0))
    (for ([e (in-vector v)])
      (check-true (valid-dim? (car e)))
      (check-true (valid-dim? (cadr e)))
      (check-not-false (or (car e) (cadr e))))))

(displayln "lab smoke-theme: ok")
