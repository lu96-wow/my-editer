#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt"
         "../atom/change.rkt" "document.rkt" rackunit)

;;; doc/batch.rkt —— 批量文本编辑（document 级）
;;;
;;;   document-apply-edit-batch  把一批互相独立、不重叠的文本编辑原子地施加
;;;
;;; 「一串 desc」的纯代数（规范化 / 位置映射 / 变更行区间）在 atom/edit.rkt。
;;;
;;; 批量文本施加只是 document-apply-change 的文本专用封装——属性跟随与撤销材料
;;; 的逻辑只有一份（在 document.rkt）。

(provide
 document-apply-edit-batch)

(define (document-apply-edit-batch d descs #:trusted? [trusted? #f])
  (document-apply-edit-batch* d descs (not trusted?)))
(define (document-apply-edit-batch* d descs guard?)
  (define-values (d* res)
    (document-apply-change d (edits->change descs) #:trusted? (not guard?)))
  (cond
    [(not res) (values d '() '())]
    [else (values d*
                  (change-result-applied-texts res)
                  (change-result-text-inverses res))]))

;;; ---------- 测试 ----------

(module+ test
  (define d0 (document-open "abcd\nefgh"))

  ;; 空批 → 原样
  (define-values (de des ive) (document-apply-edit-batch d0 '()))
  (check-eq? de d0)
  (check-equal? des '())
  (check-equal? ive '())

  ;; 两个不相交插入：倒序施加，坐标互不干扰
  (define-values (d1 d1s i1s)
    (document-apply-edit-batch d0
                             (list (edit-desc (point 0 1) (point 0 1) "X")
                                   (edit-desc (point 1 2) (point 1 2) "Y"))))
  (check-equal? (document->string d1) "aXbcd\nefYgh")
  (check-equal? (edits-map-position d1s (point 0 2)) (point 0 3))
  (check-equal? (edits-map-position d1s (point 1 2)) (point 1 3))
  (check-equal? i1s (list (edit-desc (point 1 2) (point 1 3) "")
                          (edit-desc (point 0 1) (point 0 2) "")))

  ;; 跨行删除 + 多行插入
  (define-values (d2 _d2s _i2s) (document-apply-edit-batch d0 (list (edit-desc (point 0 1) (point 1 2) "Z\nW"))))
  (check-equal? (document->string d2) "aZ\nWgh")

  ;; 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (document-apply-edit-batch d0
                           (list (edit-desc (point 0 1) (point 0 3) "X")
                                 (edit-desc (point 0 2) (point 0 4) "Y")))))

  ;; 同起点零宽插入：按列表顺序确定
  (define-values (d3 _d3s _i3s)
    (document-apply-edit-batch d0 (list (edit-desc (point 0 0) (point 0 0) "A")
                                      (edit-desc (point 0 0) (point 0 0) "B"))))
  (check-equal? (document->string d3) "ABabcd\nefgh")

  ;; 被 read-only 拒绝的编辑没发生，不污染点映射；逆与 applied 平行
  (define rbd (document-put-attr (document-open "abcd") read-only-key 0 0 2 #t))
  (define-values (rb* rdescs rinv)
    (document-apply-edit-batch rbd (list (edit-desc (point 0 1) (point 0 1) "X")   ; 只读内 → 拒
                                       (edit-desc (point 0 3) (point 0 3) "Y"))))
  (check-equal? (document->string rb*) "abcYd")
  (check-equal? rdescs (list (edit-desc (point 0 3) (point 0 3) "Y")))
  (check-equal? rinv (list (edit-desc (point 0 3) (point 0 4) "")))
  ;; #:trusted? #t：绕 read-only 强施
  (define-values (rt* rtds _rti)
    (document-apply-edit-batch rbd (list (edit-desc (point 0 1) (point 0 1) "X")) #:trusted? #t))
  (check-equal? (document->string rt*) "aXbcd")
  (check-equal? rtds (list (edit-desc (point 0 1) (point 0 1) "X")))

  (displayln "batch.rkt: all tests passed"))
