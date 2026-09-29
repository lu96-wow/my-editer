#lang racket

;;; input.rkt —— 抽象输入（后端无关）
;;;
;;; 只有三种。任何后端（终端 / GUI / 测试）把它自己的事件翻译成这三种。
;;;
;;;   key    按键：名字（char 或 symbol）+ 四个修饰位
;;;   text   一段文本（粘贴 / 输入法 / 多字符）
;;;   resize 尺寸变化
;;;
;;; 名字用 char 表示普通字符，symbol 表示命名键（'enter 'escape 'up …）。
;;; 修饰位用布尔，后端直接填；不需要任何「键编码」函数。

(provide (struct-out key)
         (struct-out text)
         (struct-out resize))

(struct key (name ctrl? alt? shift? meta?) #:transparent)
;; name : (or/c char? symbol?)
;; ctrl? / alt? / shift? / meta? : bool

(struct text (s) #:transparent)
(struct resize (rows cols) #:transparent)

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define k (key #\o #t #f #f #f))
  (check-true (key? k))
  (check-equal? (key-name k) #\o)
  (check-true (key-ctrl? k))
  (check-false (key-alt? k))

  (check-equal? (text-s (text "你好")) "你好")
  (check-equal? (resize-rows (resize 20 80)) 20)

  ;; 纯值可比较（后端与文档之间只传值）
  (check-equal? (key 'enter #f #f #f #f) (key 'enter #f #f #f #f))

  (displayln "lab-rebuild/input.rkt: all tests passed"))
