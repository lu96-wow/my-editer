#lang racket

(require "server.rkt")

;;; main.rkt —— 语言服务器入口（stdio 上的 S 表达式循环）
;;;
;;; 运行：  racket langserver/main.rkt
;;; 然后往 stdin 写请求（每行一个 S 表达式），从 stdout 读响应。

(provide main)

(define (main)
  (serve (current-input-port) (current-output-port)))

(module+ main
  (main))
