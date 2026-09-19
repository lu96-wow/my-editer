#lang racket

(require "point.rkt" "content.rkt" rackunit)

;;; marker.rkt —— 会跟着文本移动的位置
;;;
;;; 每个 marker 有 id 与 insertion-type：
;;;   'before  在 marker 位置插入时，marker 不动（留在新文本左边）
;;;   'after   在 marker 位置插入时，marker 跟到新文本右边
;;; insertion-type 只在「恰好在该点插入」时起作用；删除/合并一律是纯位置映射。
;;;
;;; 位置调整的唯一依据是 edit-desc（point 版）：
;;;   edit-desc-map-position  → 新 point 或 #f（落在被删区间内）
;;;   edit-desc-after-position → 插入文本之后的点
;;; 落在被删区间内 → 吸附到删除起点（marker 不会消失，只塌缩）。

(provide
 (struct-out marker)
 (struct-out marker-table)
 make-marker-table
 marker-table-add
 marker-table-remove
 marker-table-get
 marker-table-all
 marker-table-count
 marker-apply-edit
 marker-table-apply-edit)

;;; ---------- 数据 ----------

(struct marker (id pos insertion-type) #:transparent)
;; pos : point

(struct marker-table (next-id markers by-id) #:transparent)
;; markers : (listof marker)     迭代顺序（创建顺序）
;; by-id   : (hashof id marker)  O(1) 查找

;;; ---------- 表管理 ----------

(define (make-marker-table) (marker-table 0 '() (hash)))

(define (marker-table-add mt pos [insertion-type 'before])
  (unless (memq insertion-type '(before after))
    (error 'marker-table-add "insertion-type 必须是 'before 或 'after，得到 ~a" insertion-type))
  (define id (marker-table-next-id mt))
  (define m (marker id pos insertion-type))
  (values (marker-table (add1 id)
                        (cons m (marker-table-markers mt))
                        (hash-set (marker-table-by-id mt) id m))
          id))

(define (marker-table-remove mt id)
  (marker-table (marker-table-next-id mt)
                (filter (lambda (m) (not (= (marker-id m) id)))
                        (marker-table-markers mt))
                (hash-remove (marker-table-by-id mt) id)))

(define (marker-table-get mt id) (hash-ref (marker-table-by-id mt) id #f))
(define (marker-table-all mt) (marker-table-markers mt))
(define (marker-table-count mt) (length (marker-table-markers mt)))

;;; ---------- 调整 ----------

(define (marker-apply-edit m d)
  (define p (marker-pos m))
  (define at-start? (point=? p (edit-desc-start d)))
  (define p*
    (cond
      [(and at-start? (eq? (marker-insertion-type m) 'after))
       (edit-desc-after-position d)]
      [else
       (or (edit-desc-map-position d p)
           (edit-desc-start d))]))      ; 落在被删区间 → 塌缩到删除起点
  (marker (marker-id m) p* (marker-insertion-type m)))

(define (marker-table-apply-edit mt d)
  (define ms (map (lambda (m) (marker-apply-edit m d)) (marker-table-markers mt)))
  (marker-table (marker-table-next-id mt)
                ms
                (for/hash ([m (in-list ms)]) (values (marker-id m) m))))

;;; ---------- 测试 ----------

(module+ test
  (define d-insert (edit-desc (point 0 2) (point 0 2) "XY"))     ; 在 (0,2) 插 "XY"
  (define d-delete (edit-desc (point 0 1) (point 0 4) ""))       ; 删 [1,4)

  ;; 创建 / 查找
  (define-values (mt0 id0) (marker-table-add (make-marker-table) (point 0 5)))
  (check-equal? (marker-id (marker-table-get mt0 id0)) id0)
  (check-equal? (marker-pos (marker-table-get mt0 id0)) (point 0 5))
  (check-equal? (marker-table-count mt0) 1)
  (check-false (marker-table-get (marker-table-remove mt0 id0) id0))

  ;; 插入点之后的位置随编辑右移
  (define m-a (marker 0 (point 0 3) 'before))
  (check-equal? (marker-pos (marker-apply-edit m-a d-insert)) (point 0 5))

  ;; 恰好插入点：'before 不动，'after 跟到插入文本之后
  (check-equal? (marker-pos (marker-apply-edit (marker 0 (point 0 2) 'before) d-insert))
                (point 0 2))
  (check-equal? (marker-pos (marker-apply-edit (marker 0 (point 0 2) 'after) d-insert))
                (point 0 4))

  ;; 落在被删区间内 → 塌缩到删除起点
  (check-equal? (marker-pos (marker-apply-edit (marker 0 (point 0 2) 'before) d-delete))
                (point 0 1))
  ;; 删除之后的位置左移
  (check-equal? (marker-pos (marker-apply-edit (marker 0 (point 0 5) 'before) d-delete))
                (point 0 2))

  ;; 跨行：删除使后续行上前
  (define d-merge (edit-desc (point 0 5) (point 1 0) ""))         ; 行合并
  (check-equal? (marker-pos (marker-apply-edit (marker 0 (point 2 3) 'before) d-merge))
                (point 1 3))

  ;; 批量调整保留 id
  (define-values (mt1 id1) (marker-table-add (make-marker-table) (point 0 3)))
  (define mt2 (marker-table-apply-edit mt1 d-insert))
  (check-equal? (marker-pos (marker-table-get mt2 id1)) (point 0 5))
  (check-equal? (marker-id (marker-table-get mt2 id1)) id1)

  (displayln "marker.rkt: all tests passed"))
