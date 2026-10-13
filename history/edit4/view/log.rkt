#lang racket

;;; edit4/view/log.rkt —— 日志面板（纯投影）
;;;
;;; 日志行存在 content.log（append-only）；这里只拼接成文本 + faces。

(provide log-content)

(require racket/list
         "../core/world.rkt"
         "../content/model.rkt")

(define (log-content w v)
  (define c (world-content w))
  (define lines (content-log c))
  (values (string-join lines "\n")
          (for/list ([l (in-list lines)] [i (in-naturals)]) (cons i 'log))))
