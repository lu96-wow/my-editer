#lang racket

;;; model/chrome.rkt —— 界面附属状态：消息 / 日志 / 共享 chrome 槽（纯数据）
;;;
;;; 状态栏文本不提前拼好，而是投影层计算。
;;; chrome-slot 描述“状态栏 / 输入栏共用的区域”：
;;;   region       : region-id
;;;   status-view  : 状态栏 view-id（core view，buffer 支撑）
;;;   input-view   : 输入栏 view-id（core view，buffer 支撑）
;;; 两者在同一个 region 的 members 里，active 决定显示哪个。

(provide (struct-out chrome-slot)
         (struct-out chrome)
         make-chrome-slot
         make-chrome chrome-empty
         chrome-set-message chrome-clear-message
         chrome-log-append
         chrome-set-slot)

(struct chrome-slot (region status-view input-view) #:transparent)

(define (make-chrome-slot region status-view input-view)
  (chrome-slot region status-view input-view))

(struct chrome (message log slot-info) #:transparent)
;; message : string
;; log     : (listof string) 最新在前
;; slot    : chrome-slot | #f

(define (chrome-empty) (chrome "" '() #f))

(define (make-chrome #:message [message ""] #:log [log '()] #:slot [slot #f])
  (chrome message log slot))

(define (chrome-set-message c s) (struct-copy chrome c [message s]))
(define (chrome-clear-message c) (struct-copy chrome c [message ""]))
(define (chrome-log-append c line)
  (struct-copy chrome c [log (cons line (chrome-log c))]))
(define (chrome-set-slot c slot) (struct-copy chrome c [slot-info slot]))
