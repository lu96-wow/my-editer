#lang racket

;;; plugin-reference/indent.rkt —— 示例编辑插件：回车自动缩进
;;;
;;; 编辑插件（slot #2a）：buffer (or/c #f edit-desc) -> (listof edit-desc)
;;;   - trigger = 刚发生的编辑 desc（自动运行时非 #f）
;;;   - 只产出 edit-desc，应用/同步由框架做
;;;
;;; 行为：回车（new-text 恰为 "\n"）时，给新行补上与上一行相同的行首缩进。
;;; 其它编辑一律不动。

(require "../plugin/edit-api.rkt")

(provide indent-on-enter)

(define (indent-on-enter b trigger)
  (cond
    [(and trigger (string=? (edit-desc-new-text trigger) "\n"))
     (define prev-line (edit-desc-s-line trigger))
     (define indent (leading-whitespace (buffer-line-ref b prev-line)))
     (if (string=? indent "")
         '()
         (list (edit-desc (add1 prev-line) 0 (add1 prev-line) 0 indent)))]
    [else '()]))

;; 行首空白（空格/tab）；整行空白时返回整行
(define (leading-whitespace s)
  (let loop ([i 0])
    (cond
      [(>= i (string-length s)) s]
      [(memq (string-ref s i) '(#\space #\tab)) (loop (add1 i))]
      [else (substring s 0 i)])))

(module+ test
  (require rackunit "../core/text/buffer.rkt")

  ;; 回车后（buffer 已是 "  \nfoo"），给新行补上上一行的 "  "
  (define b0 (buffer-open "  \nfoo"))
  (define-values (b1 _d1)
    (run-edit-plugins b0 (edit-desc 0 2 0 2 "\n")
                      (list (edit-plugin-spec 'indent indent-on-enter '() 'sync))))
  (check-equal? (buffer->string b1) "  \n  foo")

  ;; 非回车编辑（插入 "("）→ 不动
  (define-values (b2 _d2)
    (run-edit-plugins b0 (edit-desc 0 0 0 0 "(")
                      (list (edit-plugin-spec 'indent indent-on-enter '() 'sync))))
  (check-eq? b2 b0)

  (displayln "indent.rkt: all tests passed"))
