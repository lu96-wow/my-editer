#lang racket

(require "point.rkt" "content.rkt" "marker.rkt" rackunit)

;;; overlay.rkt —— 独立装饰层（区间两端由 marker 锚定）
;;;
;;; 与 properties 的区别：
;;;   · 边界是 marker id（位置调整 100% 委托给 marker-table），不按行组织
;;;   · 有 priority：≤0 在 properties 之下，>0 在之上（渲染时合成 face）
;;;   · 有 evaporate?：覆盖的文本被删光（两端重合）时自动消亡
;;;
;;; 本文件不持有 marker-table，调用方传入。

(provide
 (struct-out overlay)
 (struct-out overlay-table)
 make-overlay-table
 overlay-table-add
 overlay-table-remove
 overlay-table-get
 overlay-table-all
 overlay-table-count
 overlay-table-at
 overlay-table-runs
 overlay-table-apply-edit)

;;; ---------- 数据 ----------

(struct overlay (id start-id end-id presentation priority evaporate?) #:transparent)
;; start-id / end-id : marker id
;; presentation      : hash     表现层（core 不解释）
;; priority          : int      层叠顺序
;; evaporate?        : boolean  两端重合时是否消亡

(struct overlay-table (next-id overlays by-id) #:transparent)
;; overlays : (listof overlay)    迭代顺序（创建顺序）
;; by-id    : (hashof id overlay)

;;; ---------- 表管理 ----------

(define (make-overlay-table) (overlay-table 0 '() (hash)))

;; 调用方先建好 start / end 两个 marker，再传入 id。
(define (overlay-table-add ot start-id end-id [presentation (hash)]
                           #:priority [priority 0]
                           #:evaporate? [evaporate? #f])
  (define id (overlay-table-next-id ot))
  (define ov (overlay id start-id end-id presentation priority evaporate?))
  (values (overlay-table (add1 id)
                         (cons ov (overlay-table-overlays ot))
                         (hash-set (overlay-table-by-id ot) id ov))
          id))

(define (overlay-table-remove ot id)
  (overlay-table (overlay-table-next-id ot)
                 (filter (lambda (ov) (not (= (overlay-id ov) id)))
                         (overlay-table-overlays ot))
                 (hash-remove (overlay-table-by-id ot) id)))

(define (overlay-table-get ot id) (hash-ref (overlay-table-by-id ot) id #f))
(define (overlay-table-all ot) (overlay-table-overlays ot))
(define (overlay-table-count ot) (length (overlay-table-overlays ot)))

;;; ---------- 解析 / 排序 ----------

(define (overlay-points ov mt)
  (define s (marker-table-get mt (overlay-start-id ov)))
  (define e (marker-table-get mt (overlay-end-id ov)))
  (unless (and s e)
    (error 'overlay-points "overlay ~a 引用了不存在的 marker: ~a / ~a"
           (overlay-id ov) (overlay-start-id ov) (overlay-end-id ov)))
  (values (marker-pos s) (marker-pos e)))

;; 层叠顺序：priority 降序；同 priority 时 id 小的在前（先创建的在前）。
(define (priority-descending<? a b)
  (define pa (overlay-priority a)) (define pb (overlay-priority b))
  (cond [(> pa pb) #t] [(< pa pb) #f] [else (< (overlay-id a) (overlay-id b))]))

(define (overlay-contains-point? ov mt p)
  (define-values (s e) (overlay-points ov mt))
  (and (point<=? s p) (point<? p e)))

;;; ---------- 查询 ----------

;; 覆盖 p 的所有 overlay，priority 降序（同 priority 时 id 升序）。
(define (overlay-table-at ot mt p)
  (sort (for/list ([ov (in-list (overlay-table-overlays ot))]
                   #:when (overlay-contains-point? ov mt p))
          ov)
        priority-descending<?))

;; 某行内所有 overlay 段：(listof (list start-col end-col (listof overlay)))。
;; 按 start 升序；段内 overlay 按 priority 降序。空白不出现在结果里。
(define (overlay-table-runs ot mt line line-length)
  (define spans
    (for/list ([ov (in-list (overlay-table-overlays ot))])
      (define-values (s e) (overlay-points ov mt))
      (define sl (point-line s)) (define el (point-line e))
      (cond
        [(and (= sl line) (= el line)) (list (point-col s) (point-col e) ov)]
        [(and (= sl line) (> el line)) (list (point-col s) line-length ov)]
        [(and (< sl line) (= el line)) (list 0 (point-col e) ov)]
        [(and (< sl line) (> el line)) (list 0 line-length ov)]
        [else #f])))
  (define ordered
    (sort (filter values spans)
          (lambda (a b)
            (cond [(< (car a) (car b)) #t]
                  [(> (car a) (car b)) #f]
                  [else (priority-descending<? (caddr a) (caddr b))]))))
  (cond
    [(null? ordered) '()]
    [else
     (define pts (sort (remove-duplicates
                        (append-map (lambda (sp) (list (car sp) (cadr sp))) ordered))
                       <))
     (for/list ([a (in-list (drop-right pts 1))] [b (in-list (rest pts))])
       (list a b
             (sort (for/list ([sp (in-list ordered)]
                              #:when (and (<= (car sp) a) (>= (cadr sp) b)))
                     (caddr sp))
                   priority-descending<?)))]))

;;; ---------- 编辑调整 ----------

(define (overlay-collapsed? ov mt)
  (and (overlay-evaporate? ov)
       (let-values ([(s e) (overlay-points ov mt)]) (point=? s e))))

;; 位置调整委托给 marker-table；随后 prune 已塌缩（evaporate）的 overlay。
;; 返回 (values overlay-table marker-table)。
(define (overlay-table-apply-edit ot mt d)
  (define mt* (marker-table-apply-edit mt d))
  (define kept (filter (lambda (ov) (not (overlay-collapsed? ov mt*)))
                       (overlay-table-overlays ot)))
  (values (overlay-table (overlay-table-next-id ot)
                         kept
                         (for/hash ([ov (in-list kept)]) (values (overlay-id ov) ov)))
          mt*))

;;; ---------- 测试 ----------

(module+ test
  ;; 在给定位置对建一个 overlay，返回 (values overlay-table 新 marker-table id)
  (define (add-overlay ot mt s e #:priority [pr 0] #:evaporate? [ev? #f]
                       #:presentation [pres (hash 'face 'region)])
    (define-values (mt1 sid) (marker-table-add mt s 'before))
    (define-values (mt2 eid) (marker-table-add mt1 e 'after))
    (define-values (ot* oid) (overlay-table-add ot sid eid pres
                                                #:priority pr #:evaporate? ev?))
    (values ot* mt2 oid))

  ;; at 命中 / 半开区间
  (define-values (ot1 mt1 id1) (add-overlay (make-overlay-table) (make-marker-table)
                                          (point 0 1) (point 0 4)))
  (check-equal? (length (overlay-table-at ot1 mt1 (point 0 2))) 1)
  (check-equal? (length (overlay-table-at ot1 mt1 (point 0 1))) 1)
  (check-equal? (length (overlay-table-at ot1 mt1 (point 0 4))) 0)   ; 半开
  (check-equal? (overlay-table-count ot1) 1)

  ;; runs：一行内的段
  (define runs (overlay-table-runs ot1 mt1 0 6))
  (check-equal? (length runs) 1)
  (check-equal? (list (caar runs) (cadar runs)) '(1 4))

  ;; priority 降序（同 priority 时 id 升序）
  (define-values (ot2 mt2 id2) (add-overlay (make-overlay-table) (make-marker-table)
                                          (point 0 1) (point 0 4)
                                          #:priority 0 #:presentation (hash 'k 'low)))
  (define-values (ot3 mt3 id3) (add-overlay ot2 mt2 (point 0 1) (point 0 4)
                                          #:priority 5 #:presentation (hash 'k 'high)))
  (define ats (overlay-table-at ot3 mt3 (point 0 2)))
  (check-equal? (map (lambda (o) (hash-ref (overlay-presentation o) 'k)) ats) '(high low))

  ;; 编辑：插入使 overlay 右移
  (define d-insert (edit-desc (point 0 0) (point 0 0) "XY"))
  (define-values (ot4 mt4) (overlay-table-apply-edit ot1 mt1 d-insert))
  (define rs4 (overlay-table-runs ot4 mt4 0 8))
  (check-equal? (list (caar rs4) (cadar rs4)) '(3 6))

  ;; evaporate：覆盖文本被删光 → 消亡
  (define-values (ot5 mt5 id5) (add-overlay (make-overlay-table) (make-marker-table)
                                          (point 0 1) (point 0 3) #:evaporate? #t))
  (define d-del (edit-desc (point 0 1) (point 0 3) ""))
  (define-values (ot6 mt6b) (overlay-table-apply-edit ot5 mt5 d-del))
  (check-equal? (overlay-table-count ot6) 0)

  ;; 不 evaporate 的 overlay 塌缩后保留（两端重合）
  (define-values (ot7 mt7 id7) (add-overlay (make-overlay-table) (make-marker-table)
                                          (point 0 1) (point 0 3)))
  (define-values (ot8 mt8b) (overlay-table-apply-edit ot7 mt7 d-del))
  (check-equal? (overlay-table-count ot8) 1)

  (displayln "overlay.rkt: all tests passed"))
