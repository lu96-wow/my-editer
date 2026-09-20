#lang racket

(require rackunit)

;;; atom/lines.rkt —— 文本行拆分（换行归一）
;;;
;;; 这是「字符串 ↔ 行序列」的**唯一**约定，被 content 存储、edit-desc 代数、
;;; restrictions 继承共同依赖，所以单独抽成原子，避免各层各拆一套。

(provide string->lines lines->string)

;; 把字符串按行拆开（统一行尾）：\n、\r\n、孤立 \r 都算一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (string->lines s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

;; string->lines 的逆：行序列用 \n 拼回。
(define (lines->string ls) (string-join ls "\n"))

;;; ---------- 测试 ----------

(module+ test
  ;; 换行归一（\n / \r\n / 孤立 \r）；尾换行保留空行
  (check-equal? (string->lines "a\nb") '("a" "b"))
  (check-equal? (string->lines "a\n") '("a" ""))
  (check-equal? (string->lines "") '(""))
  (check-equal? (string->lines "a\r\nb\rc") '("a" "b" "c"))
  ;; 逆：lines->string 拼回
  (check-equal? (lines->string '("a" "b")) "a\nb")
  (check-equal? (lines->string (string->lines "a\r\nb")) "a\nb")
  (displayln "lines.rkt: all tests passed"))
