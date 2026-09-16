#lang racket

(require rackunit)

;;; protocol.rkt —— 语言服务器线协议（S 表达式，非 JSON）
;;;
;;; 消息是一行一个 S 表达式（Racket read/write）：
;;;   请求： (request <id> <method> <param> ...)
;;;   响应： (response <id> <result>)
;;;   错误： (error <id> <message-string>)
;;;
;;; 为什么不用 JSON：编辑器与语言服务器都在 Racket 里，直接用原生
;;; read/write 传 S 表达式，零序列化/反序列化开销，结构、符号、精确数字
;;; 原样往返（与「数据 → lambda → 数据」一致）。

(provide write-msg read-msg)

(define (write-msg port msg)
  (write msg port)
  (newline port)
  (flush-output port))

(define (read-msg port)
  (read port))

(module+ test
  ;; 往返：write 一行 → read 回来原样
  (define in (open-input-string ""))
  (define out (open-output-string))
  (define msg (list 'request 7 'analyze "(define x 1)\n"))
  (write-msg out msg)
  (define roundtrip (read-msg (open-input-string (get-output-string out))))
  (check-equal? roundtrip msg)

  (displayln "protocol.rkt: all tests passed"))
