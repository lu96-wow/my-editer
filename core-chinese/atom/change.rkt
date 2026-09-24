#lang racket

(require "edit.rkt" "attr.rkt" "point.rkt" rackunit)

;;; atom/change.rkt —— 变更集：文本 + 属性，一次施加
;;;
;;; core 的唯一变更单位。把「替换一段文本」与「改一段属性」打包成一个值，
;;; 由唯一漏斗施加（doc/document.rkt 的 文档-施加-变更）：
;;;
;;;   · 文本集 : (listof 编辑-描述)  同一坐标系、两两不重叠；施加时按起点倒序
;;;   · 属性集 : (listof 属性-描述)  坐标 = 文本集 **全部生效之后**；同 (行,键) 不重叠
;;;
;;; 这样「插入文本 + 给插入的文本标只读」是一条命令、一次换 缓冲、一步撤销。
;;; 只做属性时 文本集 为空；只做文本时 属性集 为空。

(provide
 (struct-out 变更)
 编辑列表->变更
 属性集->变更
 变更-空?
 变更仅文本?
 变更仅属性?)

(struct 变更 (文本集 属性集) #:transparent)

(define (编辑列表->变更 ds) (变更 ds '()))
(define (属性集->变更 as) (变更 '() as))
(define (变更-空? c) (and (null? (变更-文本集 c)) (null? (变更-属性集 c))))
(define (变更仅文本? c) (null? (变更-属性集 c)))
(define (变更仅属性? c) (null? (变更-文本集 c)))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (位置 l c)))
  (check-true (变更-空? (变更 '() '())))
  (check-true (变更仅文本? (编辑列表->变更 (list (编辑-描述 (p 0 0) (p 0 0) "x")))))
  (check-false (变更仅文本? (属性集->变更 (list (属性-设置 (p 0 0) (p 0 1) 'k #t)))))
  (check-true (变更仅属性? (属性集->变更 (list (属性-设置 (p 0 0) (p 0 1) 'k #t)))))
  (check-false (变更仅属性? (编辑列表->变更 (list (编辑-描述 (p 0 0) (p 0 0) "x")))))
  (displayln "change.rkt: all tests passed"))
