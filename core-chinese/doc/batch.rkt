#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt"
         "../atom/change.rkt" "document.rkt" rackunit)

;;; doc/batch.rkt —— 批量文本编辑（文档 级）
;;;
;;;   文档-施加-编辑-批  把一批互相独立、不重叠的文本编辑原子地施加
;;;
;;; 「一串 描述」的纯代数（规范化 / 位置映射 / 变更行区间）在 atom/edit.rkt。
;;;
;;; 批量文本施加只是 文档-施加-变更 的文本专用封装——属性跟随与撤销材料
;;; 的逻辑只有一份（在 document.rkt）。

(provide
 文档-施加-编辑-批)

(define (文档-施加-编辑-批 d 描述集 #:受信? [受信? #f])
  (文档-施加-编辑-批* d 描述集 (not 受信?)))
(define (文档-施加-编辑-批* d 描述集 守卫?)
  (define-values (d* res)
    (文档-施加-变更 d (编辑列表->变更 描述集) #:受信? (not 守卫?)))
  (cond
    [(not res) (values d '() '())]
    [else (values d*
                  (变更-结果-已施加-文本集 res)
                  (变更-结果-文本-逆集 res))]))

;;; ---------- 测试 ----------

(module+ test
  (define d0 (文档-打开 "abcd\nefgh"))

  ;; 空批 → 原样
  (define-values (de des ive) (文档-施加-编辑-批 d0 '()))
  (check-eq? de d0)
  (check-equal? des '())
  (check-equal? ive '())

  ;; 两个不相交插入：倒序施加，坐标互不干扰
  (define-values (d1 d1s i1s)
    (文档-施加-编辑-批 d0
                             (list (编辑-描述 (位置 0 1) (位置 0 1) "X")
                                   (编辑-描述 (位置 1 2) (位置 1 2) "Y"))))
  (check-equal? (文档->字符串 d1) "aXbcd\nefYgh")
  (check-equal? (编辑列表-映射-位置 d1s (位置 0 2)) (位置 0 3))
  (check-equal? (编辑列表-映射-位置 d1s (位置 1 2)) (位置 1 3))
  (check-equal? i1s (list (编辑-描述 (位置 1 2) (位置 1 3) "")
                          (编辑-描述 (位置 0 1) (位置 0 2) "")))

  ;; 跨行删除 + 多行插入
  (define-values (d2 _d2s _i2s) (文档-施加-编辑-批 d0 (list (编辑-描述 (位置 0 1) (位置 1 2) "Z\nW"))))
  (check-equal? (文档->字符串 d2) "aZ\nWgh")

  ;; 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (文档-施加-编辑-批 d0
                           (list (编辑-描述 (位置 0 1) (位置 0 3) "X")
                                 (编辑-描述 (位置 0 2) (位置 0 4) "Y")))))

  ;; 同起点零宽插入：按列表顺序确定
  (define-values (d3 _d3s _i3s)
    (文档-施加-编辑-批 d0 (list (编辑-描述 (位置 0 0) (位置 0 0) "A")
                                      (编辑-描述 (位置 0 0) (位置 0 0) "B"))))
  (check-equal? (文档->字符串 d3) "ABabcd\nefgh")

  ;; 被 只读 拒绝的编辑没发生，不污染点映射；逆与 已施加 平行
  (define rbd (文档-安装-属性 (文档-打开 "abcd") 只读键 0 0 2 #t))
  (define-values (rb* rdescs rinv)
    (文档-施加-编辑-批 rbd (list (编辑-描述 (位置 0 1) (位置 0 1) "X")   ; 只读内 → 拒
                                       (编辑-描述 (位置 0 3) (位置 0 3) "Y"))))
  (check-equal? (文档->字符串 rb*) "abcYd")
  (check-equal? rdescs (list (编辑-描述 (位置 0 3) (位置 0 3) "Y")))
  (check-equal? rinv (list (编辑-描述 (位置 0 3) (位置 0 4) "")))
  ;; #:受信? #t：绕 只读 强施
  (define-values (rt* rtds _rti)
    (文档-施加-编辑-批 rbd (list (编辑-描述 (位置 0 1) (位置 0 1) "X")) #:受信? #t))
  (check-equal? (文档->字符串 rt*) "aXbcd")
  (check-equal? rtds (list (编辑-描述 (位置 0 1) (位置 0 1) "X")))

  (displayln "batch.rkt: all tests passed"))
