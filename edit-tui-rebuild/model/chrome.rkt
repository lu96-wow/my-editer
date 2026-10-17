#lang racket

;;; model/chrome.rkt —— 界面附属状态：消息 / 日志（纯数据）
;;;
;;; 状态栏文本不在这里“提前拼好”，而是投影层根据
;;;   chrome.message / 焦点 view / 文档 path / input.pending
;;; 计算。这里只保存最原始的消息，避免每帧写 buffer。

(provide (struct-out chrome)
         make-chrome chrome-empty
         chrome-set-message chrome-clear-message
         chrome-log-append)

(struct chrome (message log) #:transparent)
;; message : string          当前状态消息（空串 = 无）
;; log     : (listof string) 追加式日志（最新在前）

(define (chrome-empty) (chrome "" '()))

(define (make-chrome #:message [message ""] #:log [log '()])
  (chrome message log))

(define (chrome-set-message c s) (struct-copy chrome c [message s]))
(define (chrome-clear-message c) (struct-copy chrome c [message ""]))
(define (chrome-log-append c line)
  (struct-copy chrome c [log (cons line (chrome-log c))]))
