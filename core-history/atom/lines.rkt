#lang racket

(require rackunit)

;;; atom/lines.rkt —— 文本行拆分（换行归一）
;;;
;;; 这是「字符串 ↔ 行序列」的**唯一**约定，被 content 存储、edit-desc 代数、
;;; properties 继承共同依赖，所以单独抽成原子，避免各层各拆一套。

(provide string->lines)

;; 把字符串按行拆开（统一行尾）：\n、\r\n、孤立 \r 都算一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (string->lines s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

;;; ---------- 测试 ----------

(module+ test
  (check-equal? (string->lines "a\nb") '("a" "b"))
  (check-equal? (string->lines "a\n") '("a" ""))
  (check-equal? (string->lines "") '(""))
  (check-equal? (string->lines "a\r\nb\rc") '("a" "b" "c"))
  (displayln "lines.rkt: all tests passed"))
