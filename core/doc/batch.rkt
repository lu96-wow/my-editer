#lang racket

(require "../atom/point.rkt" "../atom/lines.rkt" "../atom/edit.rkt" "../atom/restrict.rkt" "buffer.rkt" rackunit)

;;; doc/batch.rkt —— 批量编辑应用 + 位置映射 + 变更行区间
;;;
;;; 一次编辑是 edit-desc；这里处理「一串 edit-desc」：
;;;   buffer-apply-edit-batch  把一批互相独立、不重叠的编辑原子地施加
;;;   edits-map-position       把一个点依次映射过一串（应用顺序的）编辑
;;;   edits-span               一串编辑影响到的行区间并集（增量重绘用）
;;;
;;; 全部是纯函数，数据 → 数据。

(provide
 buffer-apply-edit-batch
 edits-map-position
 edits-span)

;; 按起点（point 字典序）比较
(define (start<? a b) (point<? (edit-desc-start a) (edit-desc-start b)))

;; 输入 descs 都在 b 的同一坐标系里，互相独立、不重叠。
;; 做法：按起点倒序施加（先改后面的位置，前面未处理位置的坐标不动）。
;; 重叠（含跨行）→ 报错；同起点零宽插入按原列表顺序确定性地应用。
;; guard? = #t 走 read-only 守卫；#f 走 trusted（格式化器）。
;; 返回 (values 新 buffer applied-descs inverses)：
;;   applied-descs 按**施加顺序**（起点倒序），供 edits-map-position 按序映射；
;;   inverses 与之平行，inv_i 由「施加 desc_i 前」的 buffer 导出（no-op / 被拒的不进结果）。
(define (buffer-apply-edit-batch b descs [guard? #t])
  (cond
    [(null? descs) (values b '() '())]
    [else
     (define sorted
       (sort (for/list ([i (in-naturals)] [d (in-list descs)]) (cons i d))
             (lambda (a b)
               (define da (cdr a)) (define db (cdr b))
               (cond [(start<? da db) #t]
                     [(start<? db da) #f]
                     [else (< (car a) (car b))]))))
     ;; 升序检查相邻是否重叠（半开：next.start < prev.end 即重叠）
     (for ([a (in-list (drop-right sorted 1))] [d (in-list (rest sorted))])
       (when (point<? (edit-desc-start (cdr d)) (edit-desc-end (cdr a)))
         (error 'buffer-apply-edit-batch "编辑重叠: ~a 与 ~a" (cdr a) (cdr d))))
     (define apply (if guard? buffer-apply-edit buffer-apply-edit-trusted))
     (define-values (b* descs* invs*)
       (for/fold ([b b] [acc '()] [ivs '()]) ([it (in-list (reverse sorted))])
         (define d (cdr it))
         (define b-before b)                     ; 逆必须由「施加前」的 buffer 导出
         (define-values (b* d*) (apply b d))
         (if d*
             (values b* (cons d* acc) (cons (buffer-edit-desc-inverse b-before d*) ivs))
             (values b* acc ivs))))
     (values b* (reverse descs*) (reverse invs*))]))

;;; ---------- 点映射 ----------

;; 把 p 依次映射过 descs（**施加顺序**）。落在某次删除区间内 → 落到该区间起点。
;; 恰好落在一次零宽插入的点上 → 落到插入文本之后（光标跟随右边文本）。
(define (edits-map-position descs p)
  (for/fold ([p p]) ([d (in-list descs)])
    (cond
      [(and (point=? p (edit-desc-start d))
            (point=? (edit-desc-start d) (edit-desc-end d)))
       (edit-desc-after-position d)]
      [else (or (edit-desc-map-position d p) (edit-desc-start d))])))

;;; ---------- 变更行区间 ----------

;; 一串编辑影响到的行区间并集（新坐标系）：(values 首行 末行)；空 → (values #f #f)。
;; 单条 desc 的区间 = [start.line, start.line + 新文本行数 - 1]。
(define (edits-span descs)
  (for/fold ([f #f] [l #f]) ([d (in-list descs)])
    (define sl (point-line (edit-desc-start d)))
    (define el (+ sl (sub1 (length (string->lines (edit-desc-new-text d))))))
    (values (if f (min f sl) sl) (if l (max l el) el))))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "abcd\nefgh"))

  ;; 空批 → 原样
  (define-values (be de ive) (buffer-apply-edit-batch b0 '()))
  (check-eq? be b0)
  (check-equal? de '())
  (check-equal? ive '())

  ;; 两个不相交插入：倒序施加，坐标互不干扰
  (define-values (b1 d1s i1s)
    (buffer-apply-edit-batch b0
                             (list (edit-desc (point 0 1) (point 0 1) "X")
                                   (edit-desc (point 1 2) (point 1 2) "Y"))))
  (check-equal? (buffer->string b1) "aXbcd\nefYgh")
  (check-equal? (edits-map-position d1s (point 0 2)) (point 0 3))
  (check-equal? (edits-map-position d1s (point 1 2)) (point 1 3))
  (check-equal? i1s (list (edit-desc (point 1 2) (point 1 3) "")
                          (edit-desc (point 0 1) (point 0 2) "")))

  ;; 跨行删除 + 多行插入
  (define-values (b2 _d2 _i2) (buffer-apply-edit-batch b0 (list (edit-desc (point 0 1) (point 1 2) "Z\nW"))))
  (check-equal? (buffer->string b2) "aZ\nWgh")

  ;; 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (buffer-apply-edit-batch b0
                           (list (edit-desc (point 0 1) (point 0 3) "X")
                                 (edit-desc (point 0 2) (point 0 4) "Y")))))

  ;; 同起点零宽插入：按列表顺序确定
  (define-values (b3 _d3 _i3)
    (buffer-apply-edit-batch b0 (list (edit-desc (point 0 0) (point 0 0) "A")
                                      (edit-desc (point 0 0) (point 0 0) "B"))))
  (check-equal? (buffer->string b3) "ABabcd\nefgh")

  ;; 被 read-only 拒绝的编辑没发生，不污染点映射；逆与 applied 平行
  (define rbd (buffer-put-restrict (buffer-open "abcd") (point 0 0) (point 0 2) (restrict #t)))
  (define-values (rb* rdescs rinv)
    (buffer-apply-edit-batch rbd (list (edit-desc (point 0 1) (point 0 1) "X")   ; 只读内 → 拒
                                       (edit-desc (point 0 3) (point 0 3) "Y"))))
  (check-equal? (buffer->string rb*) "abcYd")
  (check-equal? rdescs (list (edit-desc (point 0 3) (point 0 3) "Y")))
  (check-equal? rinv (list (edit-desc (point 0 3) (point 0 4) "")))
  ;; #f 守卫：绕 read-only 强施
  (define-values (rt* rtds _rti)
    (buffer-apply-edit-batch rbd (list (edit-desc (point 0 1) (point 0 1) "X")) #f))
  (check-equal? (buffer->string rt*) "aXbcd")
  (check-equal? rtds (list (edit-desc (point 0 1) (point 0 1) "X")))

  ;; edits-span：行区间并集（新坐标系）
  (define (span ds) (call-with-values (lambda () (edits-span ds)) list))
  (check-equal? (span '()) (list #f #f))
  (check-equal? (span (list (edit-desc (point 0 1) (point 0 3) ""))) (list 0 0))
  (check-equal? (span (list (edit-desc (point 0 1) (point 0 1) "X"))) (list 0 0))
  (check-equal? (span (list (edit-desc (point 1 0) (point 1 0) "M\nN\n"))) (list 1 3))
  (check-equal? (span (list (edit-desc (point 0 0) (point 2 3) ""))) (list 0 0))
  (check-equal? (span (list (edit-desc (point 2 0) (point 2 1) "")
                            (edit-desc (point 0 0) (point 0 1) "")))
                (list 0 2))

  (displayln "edit.rkt: all tests passed"))
