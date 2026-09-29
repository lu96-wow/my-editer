#lang racket

;;; modes.rkt —— 文档模式表：did → keymap
;;;
;;; core 的 document-entry 只有 id / name / history，**没有元数据**。
;;; 「每个文档一套键位」这件事就放这里：一张纯表 did → keymap。
;;;
;;; 文档建立时登记（workspace 打开文件 / host 添加组件），关闭时移除。
;;; 同一文档的多个视图共享同一套键位 —— 这正是「按文档而非按视图」的语义。
;;;
;;; 本模块只是数据 + 存取，不含任何策略；mode 用什么键位由 bindings.rkt 决定。

(provide (struct-out modes)
         modes-empty modes-set modes-of modes-remove)

(require "keymap.rkt")

(struct modes (by-did) #:transparent)
;; by-did : hash(did → keymap)

(define (modes-empty) (modes (hash)))

(define (modes-set m did km) (modes (hash-set (modes-by-did m) did km)))
(define (modes-of m did) (hash-ref (modes-by-did m) did #f))
(define (modes-remove m did) (modes (hash-remove (modes-by-did m) did)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define k (km 'dummy '()))
  (define m0 (modes-empty))
  (check-false (modes-of m0 1))

  (define m1 (modes-set m0 1 k))
  (check-equal? (modes-of m1 1) k)
  (check-false (modes-of m1 2))

  ;; 覆盖
  (define k2 (km 'dummy2 '()))
  (check-equal? (modes-of (modes-set m1 1 k2) 1) k2)

  ;; 移除
  (check-false (modes-of (modes-remove m1 1) 1))

  (displayln "lab/modes.rkt: all tests passed"))
