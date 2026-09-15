#lang racket

(require "cursor.rkt" "content.rkt" "marker.rkt"
         "properties.rkt" "overlay.rkt" rackunit)

;;; buffer.rkt —— 编辑器核心：文本 + 位置 + 元数据 + 脏范围
;;;
;;; 组合根。所有编辑原语在这里装配：
;;;   1. sync gap 到 point
;;;   2. content-edit → (content', desc)
;;;   3. overlay-table-apply-edit ot mt desc → (ot', mt')
;;;      （内部先调 marker-table-apply-edit，再判 evaporate）
;;;   4. props-apply-edit props desc → props'
;;;   5. 更新 tick / dirty / point
;;;
;;; point 归属：buffer 持有。将来 window 出现后由 window-point 遮蔽。

(provide
 (struct-out buffer)
 (struct-out dirty-desc)
 buffer-empty
 buffer-open
 buffer->string
 buffer->lines
 buffer-line-count
 buffer-line-ref
 buffer-current-line
 buffer-goto
 buffer-left
 buffer-right
 buffer-up
 buffer-down
 buffer-home
 buffer-end
 buffer-insert
 buffer-insert-text
 buffer-newline
 buffer-backspace
 buffer-delete
 buffer-put-text-property
 buffer-get-text-property
 buffer-remove-text-property
 buffer-put-text-properties
 buffer-make-marker
 buffer-delete-marker
 buffer-marker-pos
 buffer-make-overlay
 buffer-delete-overlay
 buffer-mark-dirty
 buffer-mark-dirty-all
 buffer-clean)

;;; ---------- 结构 ----------

(struct dirty-desc (first-line last-line old-count new-count) #:transparent)

(struct buffer
  (content      ; content.rkt
   point        ; cursor.rkt       逻辑光标
   gap          ; cursor.rkt       gap 物理位置（冗余，方便断言）
   markers      ; marker-table
   properties   ; text-properties
   overlays     ; overlay-table
   tick         ; nat
   dirty        ; (or/c #f dirty-desc)
   modified?)   ; boolean
  #:transparent)

;;; ---------- 构造 ----------

(define (buffer-empty) (buffer-open ""))

(define (buffer-open s)
  (define c (content-of-string s))
  (buffer c
          (cursor 0 0)
          (cursor (content-gap-line c) (content-gap-col c))
          (make-marker-table)
          (props-empty (content-line-count c))
          (overlay-table-empty)
          0 #f #f))

;;; ---------- 投影 ----------

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines  b) (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))
(define (buffer-current-line b) (content-current-line (buffer-content b)))

;;; ---------- 光标夹紧 ----------

(define (buffer-clamp-cursor b pos)
  (define n (buffer-line-count b))
  (define l (max 0 (min (cursor-line pos) (sub1 n))))
  (define len (string-length (buffer-line-ref b l)))
  (cursor l (max 0 (min (cursor-col pos) len))))

(define (buffer-keep b pos)
  (struct-copy buffer b [point (buffer-clamp-cursor b pos)]))

;;; ---------- 导航（只动 point）----------

(define (buffer-goto b l c) (buffer-keep b (cursor l c)))

(define (buffer-left b)
  (define p (buffer-point b))
  (define l (cursor-line p))
  (define o (cursor-col p))
  (cond [(> o 0) (buffer-keep b (cursor l (sub1 o)))]
        [(> l 0) (define pl (sub1 l))
                 (define n (string-length (buffer-line-ref b pl)))
                 (buffer-keep b (cursor pl n))]
        [else b]))

(define (buffer-right b)
  (define p (buffer-point b))
  (define l (cursor-line p))
  (define o (cursor-col p))
  (define n (buffer-line-count b))
  (cond [(< o (string-length (buffer-line-ref b l))) (buffer-keep b (cursor l (add1 o)))]
        [(< l (sub1 n))                              (buffer-keep b (cursor (add1 l) 0))]
        [else b]))

(define (buffer-up b)
  (define p (buffer-point b))
  (buffer-keep b (cursor (sub1 (cursor-line p)) (cursor-col p))))

(define (buffer-down b)
  (define p (buffer-point b))
  (buffer-keep b (cursor (add1 (cursor-line p)) (cursor-col p))))

(define (buffer-home b)
  (define p (buffer-point b))
  (buffer-keep b (cursor (cursor-line p) 0)))

(define (buffer-end b)
  (define p (buffer-point b))
  (define l (cursor-line p))
  (buffer-keep b (cursor l (string-length (buffer-line-ref b l)))))

;;; ---------- dirty 计算 ----------
;;; dirty 用「新 buffer 坐标系」。渲染时直接用它索引新行表。

(define (dirty-of desc old-count new-count)
  (define s-line (edit-desc-s-line desc))
  (define k (length (string-split (edit-desc-new-text desc) "\n" #:trim? #f)))
  (define last (if (zero? k) s-line (+ s-line (sub1 k))))
  (dirty-desc s-line last old-count new-count))

(define (merge-dirty old new)
  (cond
    [(not old) new]
    [(not new) old]
    [else (dirty-desc (min (dirty-desc-first-line old) (dirty-desc-first-line new))
                      (max (dirty-desc-last-line  old) (dirty-desc-last-line  new))
                      (dirty-desc-old-count old)
                      (dirty-desc-new-count new))]))

;; 扩大「重算/重渲染」范围到 [first, last]（新坐标系，含两端）。
;; 供插件触及 dirty 之外的行时调用。不改行数（old=new），但 bump tick，
;; 以确保即使本次编辑是 no-op 也能触发渲染。
(define (buffer-mark-dirty b first last)
  (define n (buffer-line-count b))
  (define f (max 0 (min first (sub1 n))))
  (define l (max 0 (min last (sub1 n))))
  (struct-copy buffer b
    [dirty (merge-dirty (buffer-dirty b)
                        (dirty-desc (min f l) (max f l) n n))]
    [tick (add1 (buffer-tick b))]))

;; 把整个 buffer 标成 dirty（首次挂载插件时全量扫描用）。
(define (buffer-mark-dirty-all b)
  (buffer-mark-dirty b 0 (sub1 (buffer-line-count b))))

;;; ---------- 编辑核心 ----------

(define (buffer-edit b edit-fn)
  (define c1 (content-gap-goto (buffer-content b)
                               (cursor-line (buffer-point b))
                               (cursor-col  (buffer-point b))))
  (define-values (c2 desc) (edit-fn c1))
  (cond
    [(not desc) b]
    [else
     (define old-count (content-line-count c1))
     (define new-count (content-line-count c2))
     (define np (cursor (content-gap-line c2) (content-gap-col c2)))
     ;; overlay-table-apply-edit 内部先调 marker-table-apply-edit，再 prune evaporate
     (define-values (ot* mt*)
       (overlay-table-apply-edit (buffer-overlays b) (buffer-markers b) desc))
     (buffer c2 np np
             mt*
             (props-apply-edit (buffer-properties b) desc)
             ot*
             (add1 (buffer-tick b))
             (merge-dirty (buffer-dirty b) (dirty-of desc old-count new-count))
             #t)]))

(define (buffer-insert    b ch) (buffer-edit b (lambda (c) (content-insert c ch))))

;; 插入一段文本（可含 \n）：一次 splice 完成。
(define (buffer-insert-text b s)
  (buffer-edit b (lambda (c) (content-insert-text c s))))

(define (buffer-newline   b)    (buffer-edit b content-newline))
(define (buffer-backspace b)    (buffer-edit b content-backspace))
(define (buffer-delete    b)    (buffer-edit b content-delete))

;;; ---------- 属性 ----------

(define (buffer-put-text-property b line start end prop val)
  (struct-copy buffer b
    [properties (props-put (buffer-properties b) line start end prop val)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

(define (buffer-get-text-property b line col prop)
  (props-get (buffer-properties b) line col prop))

;; 只清掉 [start,end) 上某个 key。插件应只清「自己负责的 key」，避免互相清空。
(define (buffer-remove-text-property b line start end prop)
  (struct-copy buffer b
    [properties (props-remove (buffer-properties b) line start end prop)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;; 批量写属性，一次 tick：segs = (listof (list line start end prop val))
(define (buffer-put-text-properties b segs)
  (if (null? segs)
      b
      (let ([props* (for/fold ([p (buffer-properties b)]) ([s (in-list segs)])
                      (match-define (list line start end prop val) s)
                      (props-put p line start end prop val))])
        (struct-copy buffer b
          [properties props*]
          [tick (add1 (buffer-tick b))]
          [modified? #t]))))

;;; ---------- marker ----------

(define (buffer-make-marker b pos [type 'before])
  (define-values (mt id) (marker-table-add (buffer-markers b) pos type))
  (values (struct-copy buffer b
            [markers mt]
            [tick (add1 (buffer-tick b))]
            [modified? #t])
          id))

(define (buffer-delete-marker b id)
  (struct-copy buffer b
    [markers (marker-table-remove (buffer-markers b) id)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

(define (buffer-marker-pos b id)
  (define m (marker-table-get (buffer-markers b) id))
  (and m (marker-pos m)))

;;; ---------- overlay ----------

(define (buffer-make-overlay b start-pos end-pos [plist (hash)])
  (define-values (b1 sid) (buffer-make-marker b start-pos 'before))
  (define-values (b2 eid) (buffer-make-marker b1 end-pos 'after))
  (define-values (ot oid)
    (overlay-table-make (buffer-overlays b2) sid eid plist))
  (values (struct-copy buffer b2
            [overlays ot]
            [tick (add1 (buffer-tick b2))]
            [modified? #t])
          oid))

(define (buffer-delete-overlay b oid)
  (struct-copy buffer b
    [overlays (overlay-table-delete (buffer-overlays b) oid)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;;; ---------- 显示层清脏 ----------

(define (buffer-clean b)
  (struct-copy buffer b [dirty #f]))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))

  ;; 基本
  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines  b0) (list "hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-current-line b0) "hello")
  (check-equal? (buffer-point b0) (cursor 0 0))
  (check-equal? (buffer-tick b0) 0)
  (check-false (buffer-dirty b0))

  ;; insert
  (define b1 (buffer-insert b0 #\X))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? (buffer-point b1) (cursor 0 1))
  (check-equal? (buffer-tick b1) 1)
  (check-equal? (buffer-dirty b1) (dirty-desc 0 0 2 2))

  ;; newline
  (define b2 (buffer-newline b0))
  (check-equal? (buffer->string b2) "\nhello\nworld")
  (check-equal? (buffer-point b2) (cursor 1 0))
  (check-equal? (buffer-line-count b2) 3)

  ;; 之前崩的路径：down + home + backspace
  (define b3 (buffer-backspace (buffer-home (buffer-down b0))))
  (check-equal? (buffer->string b3) "helloworld")
  (check-equal? (buffer-point b3) (cursor 0 5))

  ;; delete 合并
  (define b4 (buffer-delete (buffer-end b0)))
  (check-equal? (buffer->string b4) "helloworld")
  (check-equal? (buffer-point b4) (cursor 0 5))

  ;; 导航：left / right 跨行
  (define b5 (buffer-right (buffer-end b0)))
  (check-equal? (buffer-point b5) (cursor 1 0))
  (define b6 (buffer-left b5))
  (check-equal? (buffer-point b6) (cursor 0 5))

  ;; 多行插入（paste）
  (define bp (buffer-insert-text b0 "X\nY"))
  (check-equal? (buffer->string bp) "X\nYhello\nworld")
  (check-equal? (buffer-point bp) (cursor 1 1))
  ;; 尾部换行保留空行
  (define bp2 (buffer-insert-text b0 "A\n"))
  (check-equal? (buffer->string bp2) "A\nhello\nworld")

  ;; 属性
  (define b7 (buffer-put-text-property b0 0 1 4 'face 'bold))
  (check-equal? (buffer-get-text-property b7 0 0 'face) #f)
  (check-equal? (buffer-get-text-property b7 0 2 'face) 'bold)
  (check-equal? (buffer-get-text-property b7 0 4 'face) #f)

  ;; 属性随编辑移动：插在 bold 区间内，新区间扩张
  (define b8 (buffer-insert (buffer-goto b7 0 2) #\Z))
  (check-equal? (buffer->string b8) "heZllo\nworld")
  (check-equal? (buffer-get-text-property b8 0 2 'face) 'bold)  ; 新字符继承

  ;; marker
  (define-values (b9 mid) (buffer-make-marker b0 (cursor 0 3)))
  (check-equal? (buffer-marker-pos b9 mid) (cursor 0 3))
  ;; 在 marker 前插入 → marker 右移
  (define b10 (buffer-insert b9 #\a))
  (check-equal? (buffer-marker-pos b10 mid) (cursor 0 4))
  ;; 删除 marker 前字符 → marker 左移
  (define b11 (buffer-delete (buffer-goto b10 0 0)))
  (check-equal? (buffer-marker-pos b11 mid) (cursor 0 3))

  ;; overlay
  (define-values (b12 oid) (buffer-make-overlay b0 (cursor 0 1) (cursor 0 4)
                                                 (hash 'face 'region)))
  (define b13 (buffer-insert b12 #\a))
  (define runs (overlay-table-runs (buffer-overlays b13) (buffer-markers b13) 0 10))
  (check-equal? (length runs) 1)
  (check-equal? (car  (car runs)) 2)   ; start 右移到 2
  (check-equal? (cadr (car runs)) 5)   ; end 右移到 5

  ;; overlay evaporate
  (define-values (b14 oid2) (buffer-make-overlay b0 (cursor 0 1) (cursor 0 3)
                                                  (hash 'face 'region 'evaporate #t)))
  ;; 连续删 3 次，overlay 覆盖的字符全删光
  (define b15 (buffer-delete (buffer-goto b14 0 1)))
  (define b16 (buffer-delete (buffer-goto b15 0 1)))
  (define b17 (buffer-delete (buffer-goto b16 0 1)))
  (check-equal? (overlay-table-count (buffer-overlays b17)) 0)

  ;; clean
  (check-false (buffer-dirty (buffer-clean b1)))
  (check-equal? (buffer-tick (buffer-clean b1)) 1)  ; tick 不变

  ;; tick 单调递增
  (check-equal? (buffer-tick b17)
                (+ (buffer-tick b14) 3))   ; 3 次 delete（overlay 建立的 +3 已在 b14 里）

  (displayln "buffer.rkt: all tests passed"))