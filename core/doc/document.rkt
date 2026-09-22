#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/selection.rkt" "../atom/attr.rkt" "../atom/change.rkt"
         "../unit/attrs.rkt" "buffer.rkt" racket/match racket/list rackunit)

;;; doc/document.rkt —— 可编辑根：纯文本 buffer ⊕ 标注 attrs
;;;
;;;   document = buffer ⊕ attrs
;;;
;;; buffer 只有文本与版本号（doc/buffer.rkt）；attrs 是行内标注（unit/attrs.rkt）。
;;; 二者以 **document** 装配，唯一变更漏斗也在这里：
;;;
;;;   document-apply-change        施加 change（文本 + 属性），带 read-only 守卫
;;;   document-apply-change-trusted 跳守卫
;;;   document-apply-edit[-trusted] 文本单条便利封装
;;;   document-edit[-trusted]       给位置与 op 算 desc 再施加（文本）
;;;   document-put-attr/remove-attr 属性单条便利封装
;;;
;;; 编辑传播顺序（唯一）：
;;;   content-apply（夹紧 + 生效文本 desc）
;;;   → 守卫（读 attrs）
;;;   → attrs-apply-edit（属性跟随；同时捕获被抹掉的属性，供撤销补回）
;;;   → attrs-apply-attr-batch（显式属性变更，坐标 = 文本生效之后）
;;;   → buffer tick +1
;;;
;;; core 只解释保留 key 'read-only；其余 key 对 core 不透明。派生 face 不入库
;;; （走投影参数 face-provider）。

(provide
 document?                          ; 构造器/内部字段不外露
 document-open
 document-buffer
 document-attrs
 ;; 文本委托（便利）
 document->string
 document->lines
 document-line-count
 document-line-ref
 document-line-length
 document-clamp-point
 document-point->offset
 document-offset->point
 document-range-text
 document-clamp-edit-descs
 document-text-tick
 document-attr-tick
 document-content-eq?
 document-attrs-eq?
 ;; 属性读写（通用 key→value）
 read-only-key
 attr-read-only?
 document-attrs-at
 document-attrs-runs
 document-attrs-key-runs
 document-put-attr
 document-remove-attr
 ;; 唯一变更漏斗
 document-apply-change
 document-apply-change-trusted
 document-apply-edit
 document-apply-edit-trusted
 document-edit
 document-edit-trusted
 ;; 一次变更的完整结果
 change-result
 change-result?
 change-result-applied-texts
 change-result-applied-attrs
 change-result-text-inverses
 change-result-attr-inverses
 change-result-erased-restores
 change-result-replay
 change-result-undo)

;;; ---------- 数据 ----------

(struct document
  (buffer    ; doc/buffer.rkt（content + 文本版本 tick）
   attrs     ; unit/attrs.rkt
   attr-tick); nat   标注版本（只有属性变更 +1）
  #:transparent)

;; 一次 change 的完整结果：生效 descs + 撤销材料。
(struct change-result
  (applied-texts    ; (listof edit-desc)   施加顺序（起点倒序）
   applied-attrs    ; (listof attr-desc)   施加顺序
   text-inverses    ; 与 applied-texts 平行
   attr-inverses    ; (listof (listof attr-desc))；与 applied-attrs 平行
   erased-restores) ; (listof attr-desc)   原坐标：补回被文本编辑抹掉的属性
  #:transparent)

;;; ---------- 构造 / 文本委托 ----------

(define (document-open s)
  (define b (buffer-open s))
  (document b (attrs-empty (buffer-line-count b)) 0))

(define (document->string d) (buffer->string (document-buffer d)))
(define (document->lines d)  (buffer->lines  (document-buffer d)))
(define (document-line-count d) (buffer-line-count (document-buffer d)))
(define (document-line-ref d i) (buffer-line-ref (document-buffer d) i))
(define (document-line-length d i) (buffer-line-length (document-buffer d) i))
(define (document-clamp-point d p) (buffer-clamp-point (document-buffer d) p))
(define (document-point->offset d p) (buffer-point->offset (document-buffer d) p))
(define (document-offset->point d off) (buffer-offset->point (document-buffer d) off))
(define (document-range-text d s e) (buffer-range-text (document-buffer d) s e))
(define (document-clamp-edit-descs d descs) (buffer-clamp-edit-descs (document-buffer d) descs))
;; 文本版本（只有文本变才涨）与标注版本（只有属性变才涨）分开。
(define (document-text-tick d) (buffer-tick (document-buffer d)))
(define (document-content-eq? a b)
  (buffer-content-eq? (document-buffer a) (document-buffer b)))
(define (document-attrs-eq? a b) (eq? (document-attrs a) (document-attrs b)))

;;; ---------- 属性读写 ----------

(define read-only-key 'read-only)
(define (attr-read-only? h) (eq? #t (hash-ref h read-only-key #f)))

(define (document-attrs-at d p)
  (define q (buffer-clamp-point (document-buffer d) p))
  (attrs-at (document-attrs d) q))

(define (document-attrs-runs d line)
  (attrs-runs (document-attrs d) line (buffer-line-length (document-buffer d) line)))

(define (document-attrs-key-runs d line key)
  (attrs-key-runs (document-attrs d) line (buffer-line-length (document-buffer d) line) key))

(define (document-put-attr d start end key val)
  (define-values (d* _) (document-apply-change d (attrs->change (list (attr-set start end key val)))))
  d*)
(define (document-remove-attr d start end key)
  (define-values (d* _) (document-apply-change d (attrs->change (list (attr-remove start end key)))))
  d*)

;;; ---------- read-only 守卫 ----------
;;   · 零宽插入：插入点落在只读区间的半开跨度 [start,end) 内 → 拒绝（右端点允许）
;;   · 非零宽删除：删除区间 [s,e) 与任一 read-only 段有交集 → 拒绝

(define (line-range-read-only? b attrs line a z)
  (for/or ([seg (in-list (attrs-runs attrs line (buffer-line-length b line)))])
    (match-define (list s e h) seg)
    (and (attr-read-only? h) (< (max a s) (min z e)))))

(define (range-read-only? b attrs start end)
  (define sl (point-line start)) (define sc (point-col start))
  (define el (point-line end)) (define ec (point-col end))
  (cond
    [(= sl el) (line-range-read-only? b attrs sl sc ec)]
    [else
     (or (line-range-read-only? b attrs sl sc (buffer-line-length b sl))
         (for/or ([l (in-range (add1 sl) el)])
           (line-range-read-only? b attrs l 0 (buffer-line-length b l)))
         (line-range-read-only? b attrs el 0 ec))]))

(define (desc-read-only? b attrs d)
  (define s (edit-desc-start d))
  (define e (edit-desc-end d))
  (if (point=? s e)
      (attr-read-only? (attrs-at attrs (buffer-clamp-point b s)))
      (range-read-only? b attrs s e)))

;;; ---------- 内部：低层施加 ----------

(define (bump b) (buffer-bump b))

;; 施加一条文本 desc（文本 + attrs 跟随）；tick 不变。
;; 返回 (values 新 buffer 新 attrs 生效 desc/#f)。
(define (apply-text-desc b attrs d guard?)
  (define-values (content* d*) (content-apply (buffer-content b) d))
  (cond
    [(and guard? (desc-read-only? b attrs d*)) (values b attrs #f)]
    [else
     (values (buffer-set-content b content*) (attrs-apply-edit attrs d*) d*)]))

;; change 的属性坐标 = 文本生效之后；逐条夹到生效 buffer 的行/列域。
(define (clamp-attr-desc b d)
  (define s (attr-desc-start d)) (define e (attr-desc-end d))
  (unless (= (point-line s) (point-line e))
    (error 'document-apply-change "属性区间必须同一行: ~a..~a" s e))
  (define l (point-line s))
  (when (>= l (buffer-line-count b))
    (error 'document-apply-change "属性行号越界: ~a（buffer 行数 ~a）"
           l (buffer-line-count b)))
  (define len (buffer-line-length b l))
  (define s* (point l (min (max 0 (point-col s)) len)))
  (define e* (point l (min (max 0 (point-col e)) len)))
  (when (point<? e* s*)
    (error 'document-apply-change "属性区间反向: ~a..~a" s* e*))
  (attr-desc s* e* (attr-desc-key d) (attr-desc-op d) (attr-desc-val d)))

;; 把 attrs-range-runs 的 (line a b hash) 展开成每条 key 一条 attr-set。
(define (runs->attr-descs runs)
  (append*
   (for/list ([r (in-list runs)])
     (match-define (list line x y h) r)
     (for/list ([(k v) (in-hash h)])
       (attr-set (point line x) (point line y) k v)))))

;; 文本批：规范化 → 按起点倒序施加 → attrs 跟随 → 捕获被抹属性。tick 不变。
(define (apply-text-batch b attrs descs guard?)
  (define ordered (edits-normalize 'document-apply-change descs))
  (define-values (b* a* applied invs erased)
    (for/fold ([b b] [attrs attrs] [applied '()] [invs '()] [erased '()])
              ([d (in-list (reverse ordered))])
      (define b-before b) (define attrs-before attrs)
      (define-values (bb aa dd) (apply-text-desc b attrs d guard?))
      (cond
        [(not dd) (values bb aa applied invs erased)]
        [else
         (define er (runs->attr-descs
                     (attrs-range-runs attrs-before (edit-desc-start dd) (edit-desc-end dd))))
         (values bb aa (cons dd applied)
                 (cons (buffer-edit-desc-inverse b-before dd) invs)
                 (append erased er))])))
  (values b* a* (reverse applied) (reverse invs) erased))

(define (document-apply-change d ch) (document-apply-change* d ch #t))
(define (document-apply-change-trusted d ch) (document-apply-change* d ch #f))
(define (document-apply-change* d ch guard?)
  (define b0 (document-buffer d))
  (define-values (b1 attrs1 applied-texts text-invs erased)
    (apply-text-batch b0 (document-attrs d) (change-texts ch) guard?))
  (define eff-attrs
    (filter-map (lambda (x)
                  (define x* (clamp-attr-desc b1 x))
                  (and (not (attr-desc-empty? x*)) x*))
                (change-attrs ch)))
  (define attr-invs (map (lambda (x) (attrs-desc-inverse attrs1 x)) eff-attrs))
  (define attrs* (attrs-apply-attr-batch attrs1 'document-apply-change eff-attrs))
  (define text? (pair? applied-texts))
  (define attrs? (pair? eff-attrs))
  (cond
    [(and (not text?) (not attrs?)) (values d #f)]
    [else
     (values (document (if text? (bump b1) b1)
                       attrs*
                       (if attrs? (add1 (document-attr-tick d)) (document-attr-tick d)))
             (change-result applied-texts eff-attrs text-invs attr-invs erased))]))

;;; ---------- 便利入口 ----------

;; 文本单条：返回 (values document 生效desc/#f)。
(define (document-apply-edit d desc) (document-apply-edit* d desc #t))
(define (document-apply-edit-trusted d desc) (document-apply-edit* d desc #f))
(define (document-apply-edit* d desc guard?)
  (define-values (d* res) (document-apply-change* d (edits->change (list desc)) guard?))
  (define ds (if res (change-result-applied-texts res) '()))
  (values d* (and (pair? ds) (car ds))))

;; 给位置与 op（buffer selection → desc/#f），算 desc 再施加。
(define (document-edit d p op) (document-edit* d p op #t))
(define (document-edit-trusted d p op) (document-edit* d p op #f))
(define (document-edit* d p op guard?)
  (define desc (op (document-buffer d) (selection p p)))
  (if desc
      (document-apply-edit* d desc guard?)
      (values d #f)))

;;; ---------- 重放 / 撤销材料 ----------

(define (change-result-replay res)
  (change (change-result-applied-texts res) (change-result-applied-attrs res)))
(define (change-result-undo res)
  (append
   ;; ① 显式属性的逆：同一（post）坐标，可批
   (list (attrs->change (append* (reverse (change-result-attr-inverses res)))))
   ;; ② 文本逆：与 applied 平行，每条坐标基于「上一条之后」——必须逆序、逐条施加
   (for/list ([x (in-list (reverse (change-result-text-inverses res)))])
     (edits->change (list x)))
   ;; ③ 被抹掉的属性：此时文本已复原，用原坐标补回
   (list (attrs->change (change-result-erased-restores res)))))

;;; ---------- 测试 ----------

(module+ test
  (define P (lambda (l c) (point l c)))
  (define ro (hash read-only-key #t))

  ;; 构造：buffer + attrs
  (define d0 (document-open "hello\nworld"))
  (check-equal? (document->string d0) "hello\nworld")
  (check-equal? (document-line-count d0) 2)
  (check-equal? (attrs-line-count (document-attrs d0)) 2)

  ;; 文本编辑
  (define-values (d1 e1) (document-edit d0 (P 0 0) (buffer-op-insert-char #\X)))
  (check-equal? (document->string d1) "Xhello\nworld")
  (check-equal? e1 (edit-desc (P 0 0) (P 0 0) "X"))
  (check-equal? (document-text-tick d1) 1)             ; 文本版本
  (check-equal? (document-attr-tick d1) 0)

  ;; 属性读写：任意 key 独立；read-only 是保留 key
  (define ab (document-put-attr d0 (P 0 1) (P 0 4) 'face 'bold))
  (check-equal? (document-attrs-at ab (P 0 2)) (hash 'face 'bold))
  (check-equal? (document-attrs-key-runs ab 0 'face) (list (list 1 4 'bold)))
  (define ab2 (document-put-attr ab (P 0 2) (P 0 3) read-only-key #t))
  (check-equal? (document-attrs-at ab2 (P 0 2)) (hash 'face 'bold read-only-key #t))
  (define ab3 (document-remove-attr ab2 (P 0 2) (P 0 3) read-only-key))
  (check-false (attr-read-only? (document-attrs-at ab3 (P 0 2))))
  (check-true (document-content-eq? d0 ab))       ; 写属性不动文本
  (check-equal? (document-text-tick ab) 0)             ; 文本版本不变
  (check-equal? (document-attr-tick ab) 1)        ; 标注版本 +1

  ;; 零宽 = no-op
  (check-eq? (document-put-attr d0 (P 0 1) (P 0 1) 'k #t) d0)
  (check-eq? (document-remove-attr ab (P 0 2) (P 0 2) 'face) ab)
  ;; 跨行 / 越界 → 报错
  (check-exn exn:fail? (lambda () (document-put-attr d0 (P 0 0) (P 1 0) 'k #t)))
  (check-exn exn:fail? (lambda () (document-put-attr d0 (P 9 0) (P 9 1) 'k #t)))

  ;; read-only 守卫
  (define rb (document-put-attr d0 (P 0 1) (P 0 4) read-only-key #t))
  (define-values (rb1 rrd) (document-edit rb (P 0 2) (buffer-op-insert-char #\X)))
  (check-eq? rb1 rb)
  (check-false rrd)
  (define-values (rb2 _) (document-edit rb (P 0 4) (buffer-op-insert-char #\X)))
  (check-equal? (document->string rb2) "hellXo\nworld")
  (check-false (attr-read-only? (document-attrs-at rb2 (P 0 4))))
  (define-values (rb4 rrd4) (document-edit-trusted rb (P 0 2) (buffer-op-insert-char #\X)))
  (check-equal? (document->string rb4) "heXllo\nworld")
  (check-equal? rrd4 (edit-desc (P 0 2) (P 0 2) "X"))

  ;; 枚举 / 清属性
  (check-equal? (document-attrs-runs rb 0)
                (list (list 0 1 (hash)) (list 1 4 ro) (list 4 5 (hash))))
  (define rb-nr (document-remove-attr rb (P 0 1) (P 0 4) read-only-key))
  (check-false (attr-read-only? (document-attrs-at rb-nr (P 0 2))))
  (check-equal? (document-attrs-runs rb-nr 0) (list (list 0 5 (hash))))

  ;; 文本 + 属性一条 change：一次施加、一步 tick、report 含两者
  (define cb0 (document-open "abc"))
  (define-values (cb1 res)
    (document-apply-change cb0
      (change (list (edit-desc (P 0 1) (P 0 1) "X"))
              (list (attr-set (P 0 1) (P 0 2) read-only-key #t)))))
  (check-equal? (document->string cb1) "aXbc")
  (check-equal? (document-attrs-key-runs cb1 0 read-only-key) (list (list 1 2 #t)))
  (check-equal? (document-text-tick cb1) 1)            ; 文本版本
  (check-equal? (document-attr-tick cb1) 1)       ; 标注版本
  (check-equal? (change-result-applied-texts res) (list (edit-desc (P 0 1) (P 0 1) "X")))
  (check-equal? (change-result-applied-attrs res)
                (list (attr-set (P 0 1) (P 0 2) read-only-key #t)))
  (check-equal? (change-result-replay res)
                (change (list (edit-desc (P 0 1) (P 0 1) "X"))
                        (list (attr-set (P 0 1) (P 0 2) read-only-key #t))))

  ;; 撤销辅助
  (define (apply-undo d res)
    (for/fold ([x d]) ([c (in-list (change-result-undo res))])
      (let-values ([(x* _) (document-apply-change-trusted x c)]) x*)))

  (define cb2 (apply-undo cb1 res))
  (check-equal? (document->string cb2) "abc")
  (check-false (attr-read-only? (document-attrs-at cb2 (P 0 1))))

  ;; 回归：删除带属性的文本，撤销必须把属性一起带回
  (define eb0 (document-put-attr (document-open "abc") (P 0 0) (P 0 3) read-only-key #t))
  (define-values (eb1 res2)
    (document-apply-change-trusted eb0 (edits->change (list (edit-desc (P 0 1) (P 0 2) "")))))
  (check-equal? (document->string eb1) "ac")
  (check-equal? (document-attrs-key-runs eb1 0 read-only-key) (list (list 0 2 #t)))
  (define eb2 (apply-undo eb1 res2))
  (check-equal? (document->string eb2) "abc")
  (check-equal? (document-attrs-key-runs eb2 0 read-only-key) (list (list 0 3 #t)))

  ;; 守卫拒绝 → 什么都没发生
  (define gb (document-put-attr (document-open "abc") (P 0 0) (P 0 1) read-only-key #t))
  (define-values (gb1 res3) (document-apply-change gb (edits->change (list (edit-desc (P 0 0) (P 0 0) "Z")))))
  (check-equal? (document->string gb1) "abc")
  (check-false res3)

  (displayln "document.rkt: all tests passed"))
