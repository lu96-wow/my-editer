#lang racket

;;; key.rkt —— 键归一：把「名字 + 修饰键」压成一个 token
;;;
;;; 键位表（keymap.rkt）只认一种东西 —— token：
;;;   · 无修饰命名键        'up 'enter 'escape 'tab 'backspace 'del
;;;   · 无修饰可打印字符    #\a #\n #\space
;;;   · 带修饰键            'C-o 'M-up 'S-left 'CS-down（修饰序固定 C M S）
;;;   · 多字符输入（粘贴）  'text（内容放在 stroke 的 arg）
;;;
;;; 本模块**不认识终端事件结构体**，只吃三个布尔（ctrl/alt/shift）。
;;; 「事件 → 三个布尔」的提取留在 tui.rkt —— 于是本层可以脱离终端单测。
;;;
;;; stroke = 一次规范化输入 = token ⊕ arg：
;;;   token 用于查键位表；arg 只有 'text 用（剪贴板 / 多字符），单字符放 token 本身。
;;;
;;; 「哪些 stroke 算文本」由 text-stroke? 判定：char token 或 'text。
;;; 键位表的默认兜底只对文本 stroke 生效（见 dispatch.rkt）。

(provide (struct-out stroke)
         make-stroke make-stroke-text key-token
         text-stroke? stroke-text)

(struct stroke (token arg) #:transparent)
;; token : (or/c char? symbol?)
;; arg   : (or/c #f string)    仅 'text 用

;; 是否文本类输入（键位表的 default 兜底只吃这类）。
(define (text-stroke? s)
  (or (char? (stroke-token s)) (eq? 'text (stroke-token s))))

;; 该 stroke 对应的输入文本（非文本类 → #f）。
(define (stroke-text s)
  (cond [(char? (stroke-token s)) (string (stroke-token s))]
        [(eq? 'text (stroke-token s)) (stroke-arg s)]
        [else #f]))

(define (make-stroke token [arg #f]) (stroke token arg))

;; 一段输入文本 → stroke：单字符用 char token，多字符（粘贴）用 'text。
(define (make-stroke-text s)
  (if (= 1 (string-length s))
      (stroke (string-ref s 0) #f)
      (stroke 'text s)))

;; 名字 + 修饰布尔 → token。命名键用 symbol 名，字符用 char（无修饰时保持原样）。
(define (key-token name ctrl? alt? shift?)
  (define flags (string-append (if ctrl? "C" "") (if alt? "M" "") (if shift? "S" "")))
  (define base (if (char? name) (string (char-downcase name)) (symbol->string name)))
  (cond
    [(string=? flags "") (if (char? name) name (string->symbol base))]
    [else (string->symbol (format "~a-~a" flags base))]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (check-equal? (key-token 'up #f #f #f) 'up)
  (check-equal? (key-token 'enter #f #f #f) 'enter)
  (check-equal? (key-token #\a #f #f #f) #\a)
  (check-equal? (key-token #\O #t #f #f) 'C-o)        ; 字母归一小写
  (check-equal? (key-token 'down #t #f #t) 'CS-down)
  (check-equal? (key-token 'up #f #t #f) 'M-up)
  (check-equal? (key-token 'left #f #f #t) 'S-left)

  (define s1 (make-stroke-text "a"))
  (check-equal? (stroke-token s1) #\a)
  (check-true (text-stroke? s1))
  (check-equal? (stroke-text s1) "a")

  (define s2 (make-stroke-text "abc"))
  (check-equal? (stroke-token s2) 'text)
  (check-equal? (stroke-text s2) "abc")
  (check-true (text-stroke? s2))

  (define s3 (make-stroke 'C-o))
  (check-false (text-stroke? s3))
  (check-false (stroke-text s3))

  (displayln "lab/key.rkt: all tests passed"))
