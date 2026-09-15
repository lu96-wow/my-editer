#lang racket

(require "cursor.rkt" "content.rkt" "marker.rkt" rackunit)

;;; overlay.rkt —— 独立装饰层
;;;
;;; 与 properties 的区别：
;;;   - 边界是 marker id，位置调整委托给 marker-table
;;;   - 全局 id 索引，不按行组织
;;;   - 有 priority，渲染时决定覆盖顺序
;;;   - 有 evaporate，覆盖文本被删光时自动消亡
;;;
;;; 不变量：
;;;   O1  每个 overlay 的 start-id / end-id 都能在 marker-table 里找到
;;;   O2  start 位置 <= end 位置（基于当前 marker 位置）
;;;
;;; 本文件不直接持有 marker-table；调用者传入。

(provide
 (struct-out overlay)
 (struct-out overlay-table)
 overlay-table-empty
 overlay-table-make
 overlay-table-delete
 overlay-table-get
 overlay-table-all
 overlay-table-count
 overlay-priority
 overlay-table-at
 overlay-table-runs
 overlay-table-apply-edit)

(struct overlay (id start-id end-id plist) #:transparent)
;; start-id, end-id : marker-id
;; plist : immutable hash

(struct overlay-table (next-id overlays by-id) #:transparent)
;; overlays : (listof overlay)     迭代顺序
;; by-id    : (hashof id overlay)  O(1) 查找

;;; ---------- 构造 ----------

(define (overlay-table-empty) (overlay-table 0 '() (hash)))

;; 需要调用者先给 start / end 建 marker，再传入它们的 id。
(define (overlay-table-make ot start-id end-id [plist (hash)])
  (define id (overlay-table-next-id ot))
  (define ov (overlay id start-id end-id plist))
  (values (overlay-table (add1 id)
                         (cons ov (overlay-table-overlays ot))
                         (hash-set (overlay-table-by-id ot) id ov))
          id))

(define (overlay-table-delete ot id)
  (overlay-table (overlay-table-next-id ot)
                 (filter (lambda (ov) (not (= (overlay-id ov) id)))
                         (overlay-table-overlays ot))
                 (hash-remove (overlay-table-by-id ot) id)))

(define (overlay-table-get ot id)
  (hash-ref (overlay-table-by-id ot) id #f))

(define (overlay-table-all ot) (overlay-table-overlays ot))
(define (overlay-table-count ot) (length (overlay-table-overlays ot)))

;;; ---------- 查询 ----------

(define (overlay-priority ov)
  (hash-ref (overlay-plist ov) 'priority 0))

;; 把 overlay 的 id 对解析成 cursor 对
(define (overlay-cursors ov mt)
  (define s (marker-table-get mt (overlay-start-id ov)))
  (define e (marker-table-get mt (overlay-end-id ov)))
  (unless (and s e)
    (error 'overlay-cursors
           "overlay ~a references missing marker(s) ~a / ~a"
           (overlay-id ov) (overlay-start-id ov) (overlay-end-id ov)))
  (values (marker-pos s) (marker-pos e)))

(define (overlay-contains-cursor? ov mt pos)
  (define-values (s e) (overlay-cursors ov mt))
  (and (cursor<=? s pos) (cursor<? pos e)))

;; 返回覆盖 (line, col) 的所有 overlay，按 priority 降序（高 priority 在前）。
;; 同 priority 时 id 小的在前（先创建的在前）。
(define (overlay-table-at ot mt line col)
  (define pos (cursor line col))
  (sort (for/list ([ov (in-list (overlay-table-overlays ot))]
                   #:when (overlay-contains-cursor? ov mt pos))
          ov)
        (lambda (a b)
          (define pa (overlay-priority a))
          (define pb (overlay-priority b))
          (cond [(> pa pb) #t]
                [(< pa pb) #f]
                [else (< (overlay-id a) (overlay-id b))]))))

;; 渲染扫描：某行内所有 overlay 段，返回
;; (listof (list start-col end-col (listof overlay)))
;; 按 start 升序；同段内 overlay 已按 priority 降序排好。
;; 空白位置不出现在结果里（properties-runs 会填 empty-plist）。
(define (overlay-table-runs ot mt line line-length)
  (define ovs-with-span
    (for/list ([ov (in-list (overlay-table-overlays ot))])
      (define-values (s e) (overlay-cursors ov mt))
      (define sl (cursor-line s))
      (define el (cursor-line e))
      ;; 只保留与本行有交集的
      (cond
        [(and (= sl line) (= el line))
         (list (cursor-col s) (cursor-col e) ov)]
        [(and (= sl line) (> el line))
         (list (cursor-col s) line-length ov)]
        [(and (< sl line) (= el line))
         (list 0 (cursor-col e) ov)]
        [(and (< sl line) (> el line))
         (list 0 line-length ov)]
        [else #f])))
  (define spans (filter values ovs-with-span))
  ;; 按 start 升序；同 start 按 priority 降序
  (define ordered
    (sort spans
          (lambda (a b)
            (cond [(< (car a) (car b)) #t]
                  [(> (car a) (car b)) #f]
                  [else (> (overlay-priority (caddr a))
                           (overlay-priority (caddr b)))]))))
  ;; 按边界切成 runs
  (cond
    [(null? ordered) '()]
    [else
     (define points
       (sort (remove-duplicates
              (append-map (lambda (sp) (list (car sp) (cadr sp))) ordered))
             <))
     (for/list ([a (in-list (drop-right points 1))]
                [b (in-list (rest points))])
       (define covering
         (sort (for/list ([sp (in-list ordered)]
                          #:when (and (<= (car sp) a) (>= (cadr sp) b)))
                 (caddr sp))
               (lambda (x y)
                 (define px (overlay-priority x))
                 (define py (overlay-priority y))
                 (cond [(> px py) #t]
                       [(< px py) #f]
                       [else (< (overlay-id x) (overlay-id y))]))))
       ;; covering 已按 priority 降序（同 priority 时 id 小的在前）
       (list a b covering))]))

;;; ---------- 编辑调整 ----------
;;;
;;; 位置调整 100% 委托给 marker-table-apply-edit。
;;; 本函数只负责：evaporate 判定 + marker-table 的搬运。

(define (overlay-evaporates? ov mt)
  (and (hash-ref (overlay-plist ov) 'evaporate #f)
       (let-values ([(s e) (overlay-cursors ov mt)])
         (cursor=? s e))))

(define (overlay-table-apply-edit ot mt desc)
  ;; 1. marker-table 一次性调整
  (define mt* (marker-table-apply-edit mt desc))
  ;; 2. 检查 evaporate
  (define kept
    (filter (lambda (ov) (not (overlay-evaporates? ov mt*)))
            (overlay-table-overlays ot)))
  (values (overlay-table (overlay-table-next-id ot)
                         kept
                         (for/hash ([ov (in-list kept)])
                           (values (overlay-id ov) ov)))
          mt*))
