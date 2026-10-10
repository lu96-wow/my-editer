#lang racket

;;; edit-rebuild/core/session/ui-state.rkt —— 界面状态（纯）
;;;
;;; 局部问题：屏幕尺寸 / 退出标志 / 视图显隐 / 日志。都是「界面级」的，与文档、
;;; 输入、几何无关。操作都是纯字段变换（返回新值）。

(provide (struct-out ui-state)
         ui-state-new
         ui-resize ui-quit ui-visible? ui-set-visible ui-log-add)

(struct ui-state (width height quit? presentations log) #:transparent)
;; width height  : 屏幕尺寸
;; quit?         : 退出标志
;; presentations : (hash vid -> boolean)   显隐（缺省 = 可见）
;; log           : (listof string)         只读日志

(define (ui-state-new width height)
  (ui-state width height #f (hash) '()))

(define (ui-resize u width height)
  (struct-copy ui-state u [width width] [height height]))

(define (ui-quit u) (struct-copy ui-state u [quit? #t]))

(define (ui-visible? u vid) (hash-ref (ui-state-presentations u) vid #t))

(define (ui-set-visible u vid on?)
  (struct-copy ui-state u
    [presentations (hash-set (ui-state-presentations u) vid on?)]))

(define (ui-log-add u lines)
  (struct-copy ui-state u [log (append (ui-state-log u) lines)]))
