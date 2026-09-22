#lang racket

(require "edit.rkt" "attr.rkt" "point.rkt" rackunit)

;;; atom/change.rkt —— 变更集：文本 + 属性，一次施加
;;;
;;; core 的唯一变更单位。把「替换一段文本」与「改一段属性」打包成一个值，
;;; 由唯一漏斗施加（doc/document.rkt 的 document-apply-change）：
;;;
;;;   · texts : (listof edit-desc)  同一坐标系、两两不重叠；施加时按起点倒序
;;;   · attrs : (listof attr-desc)  坐标 = texts **全部生效之后**；同 (line,key) 不重叠
;;;
;;; 这样「插入文本 + 给插入的文本标只读」是一条命令、一次换 buffer、一步撤销。
;;; 只做属性时 texts 为空；只做文本时 attrs 为空。

(provide
 (struct-out change)
 edits->change
 attrs->change
 change-empty?
 change-text-only?
 change-attr-only?)

(struct change (texts attrs) #:transparent)

(define (edits->change ds) (change ds '()))
(define (attrs->change as) (change '() as))
(define (change-empty? c) (and (null? (change-texts c)) (null? (change-attrs c))))
(define (change-text-only? c) (null? (change-attrs c)))
(define (change-attr-only? c) (null? (change-texts c)))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (point l c)))
  (check-true (change-empty? (change '() '())))
  (check-true (change-text-only? (edits->change (list (edit-desc (p 0 0) (p 0 0) "x")))))
  (check-false (change-text-only? (attrs->change (list (attr-set (p 0 0) (p 0 1) 'k #t)))))
  (check-true (change-attr-only? (attrs->change (list (attr-set (p 0 0) (p 0 1) 'k #t)))))
  (check-false (change-attr-only? (edits->change (list (edit-desc (p 0 0) (p 0 0) "x")))))
  (displayln "change.rkt: all tests passed"))
