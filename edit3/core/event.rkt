#lang racket

;;; edit3/event.rkt —— Event ADT
;;;
;;; 事件是数据：输入 / 并发结果 / 定时走同一条流。
;;; 守卫构造子（on-key / on-cursor …）声明式，直接进路由表。

(provide (struct-out key-event) (struct-out text-event)
         (struct-out cursor-event) (struct-out resize-event)
         (struct-out job-event) (struct-out tick-event)
         key-is? on-key on-text on-cursor on-resize on-job)

(struct key-event (key mods) #:transparent)        ; mods : (listof symbol)
(struct text-event (text) #:transparent)           ; 直接输入的文本（可能多字符）
;; 指针：屏幕 0-based 列/行；kind 'press|'release|'move|'scroll
(struct cursor-event (kind button x y) #:transparent)
(struct resize-event (w h) #:transparent)
(struct job-event (id kind result tag) #:transparent)   ; 后台结果回注（tag 原样带回）
(struct tick-event (dt) #:transparent)

;;; ---------- 守卫构造子 ----------

(define (key-is? ev key [mods '()])
  (and (key-event? ev)
       (eq? key (key-event-key ev))
       (equal? (sort (key-event-mods ev) symbol<?) (sort mods symbol<?))))

(define ((on-key key [mods '()]) st ev)
  (key-is? ev key mods))

;; (text) 任意文本； (text "f") 只匹配该串（普通可打印字符走 text-event，不走 key-event）
(define ((on-text [str #f]) st ev)
  (and (text-event? ev)
       (or (not str) (equal? str (text-event-text ev)))))
(define (on-resize st ev) (resize-event? ev))
(define (on-job st ev) (job-event? ev))

;; (on-cursor 'press 'left) / (on-cursor 'scroll) / (on-cursor 'move)
(define ((on-cursor kind [button #f]) st ev)
  (and (cursor-event? ev)
       (eq? kind (cursor-event-kind ev))
       (or (not button) (eq? button (cursor-event-button ev)))))
