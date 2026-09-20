#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/restrict.rkt" "../atom/selection.rkt"
         "../unit/properties.rkt" "../unit/marker.rkt" "../unit/overlay.rkt" rackunit)

;;; doc/buffer.rkt —— 文档：文本 + 属性 + 标记 + 装饰（无光标）
;;;
;;; 装配根。buffere 把所有层绑成一个值，并提供唯一的编辑入口：
;;;
;;;   buffer-apply-edit b desc           过一次编辑，传播到所有层（含 read-only 守卫）
;;;   buffer-apply-edit-trusted b desc   同上，跳过守卫（撤销/重放用）
;;;   buffer-edit b point op             算一条 desc（op）再施加，是 buffer 层的编辑入口
;;;
;;; 光标不在 buffer 里：一个 buffer 可被多个 window 绑定，各有自己的 point。
;;; 所以本层所有编辑都显式收 point / edit-desc，不保存「当前位置」。
;;;
;;; 编辑传播顺序（唯一）：
;;;   content-apply（夹紧 + 有效 desc）→ 守卫 → overlay-table（内含 marker-table）→ properties。
;;; 各层都吃**同一个**生效 desc（content-apply 的返回值），保证坐标一致。

(provide
 (struct-out buffer)
 buffer-open
 buffer->string
 buffer->lines
 buffer-line-count
 buffer-line-ref
 buffer-line-length
 buffer-clamp-point
 buffer-point->offset
 buffer-offset->point
 buffer-apply-edit
 buffer-apply-edit-trusted
 buffer-edit
 edit-insert-char
 edit-insert
 edit-newline
 edit-backspace
 edit-delete
 edit-splice
 buffer-edit-desc-inverse
 buffer-range-text
 buffer-put-property
 buffer-get-property
 buffer-remove-property
 buffer-put-properties-many
 buffer-put-restrict
 buffer-remove-restrict
 buffer-restrict-at
 buffer-restrict-runs
 buffer-property-runs
 buffer-add-marker
 buffer-remove-marker
 buffer-marker-pos
 buffer-add-overlay
 buffer-remove-overlay
 buffer-overlay-at
 buffer-overlay-runs
 buffer-tick
 buffer-content
 buffer-markers
 buffer-properties
 buffer-overlays)

;;; ---------- 数据 ----------

(struct buffer
  (content      ; content.rkt
   markers      ; marker-table
   properties   ; properties
   overlays     ; overlay-table
   tick)        ; nat      任何改动 +1（编辑 / 属性 / marker / overlay）
  #:transparent)

;;; ---------- 构造 / 投影 ----------

(define (buffer-open s)
  (define c (content-of-string s))
  (buffer c (make-marker-table) (make-properties (content-line-count c))
          (make-overlay-table) 0))

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines b)  (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))
(define (buffer-line-length b i) (content-line-length (buffer-content b) i))
;; 位置解析只取决于 buffer（content），与任何 window/光标无关。
(define (buffer-clamp-point b p) (content-clamp-point (buffer-content b) p))
(define (buffer-point->offset b p) (content-point->offset (buffer-content b) p))
(define (buffer-offset->point b off) (content-offset->point (buffer-content b) off))

;;; ---------- read-only 守卫 ----------
;; 规则（显式契约）：
;;   · 零宽插入：插入点落在只读区间的半开跨度 [start,end) 内 → 拒绝（右端点允许）
;;   · 非零宽删除：删除区间 [s,e) 与任一 read-only 段有交集 → 拒绝
;; 程序要编辑 read-only 内容，走显式入口 buffer-apply-edit-trusted / buffer-splice 的 trusted 版。

;; 某点的约束槽。读口；想只要「是否只读」用 (restrict-read-only? (buffer-restrict-at …))。
(define (buffer-restrict-at b p)
  (properties-restrict-at (buffer-properties b) (point-line p) (point-col p)))

;; 一行内约束槽的段：(listof (list start end restrict))，恰好覆盖整行。
;; 枚举只读区间用（O(段数)）。
(define (buffer-restrict-runs b line)
  (properties-restrict-runs (buffer-properties b) line
                            (string-length (buffer-line-ref b line))))

;; 一行内某表现层 key 的段：(listof (list start end val))，只含该 key 存在的段。
;; 区间查询（诊断/高亮读回）用（O(段数)）。
(define (buffer-property-runs b line key)
  (filter caddr
          (properties-key-runs (buffer-properties b) line
                               (string-length (buffer-line-ref b line)) key)))

;; [a,z) 与某行任一 read-only 段有交集？
(define (line-range-read-only? b line a z)
  (for/or ([seg (in-list (buffer-restrict-runs b line))])
    (match-define (list s e rs) seg)
    (and (restrict-read-only? rs) (< (max a s) (min z e)))))

(define (range-read-only? b start end)
  (define sl (point-line start)) (define sc (point-col start))
  (define el (point-line end)) (define ec (point-col end))
  (cond
    [(= sl el) (line-range-read-only? b sl sc ec)]
    [else
     (or (line-range-read-only? b sl sc (string-length (buffer-line-ref b sl)))
         (for/or ([l (in-range (add1 sl) el)])
           (line-range-read-only? b l 0 (string-length (buffer-line-ref b l))))
         (line-range-read-only? b el 0 ec))]))

(define (desc-read-only? b d)
  (define s (edit-desc-start d))
  (define e (edit-desc-end d))
  (if (point=? s e)
      (restrict-read-only? (buffer-restrict-at b s))
      (range-read-only? b s e)))

;;; ---------- 编辑：唯一传播点 ----------

;; 应用一条 edit-desc 到所有层。guard? = #f 时跳过 read-only 守卫。
;; 返回 (values 新 buffer 生效 desc)；被守卫拒绝或内容无变化（desc #f 不会到这）→ desc = #f。
(define (buffer-apply-edit* b d guard?)
  (define-values (content* d*) (content-apply (buffer-content b) d))
  (cond
    [(and guard? (desc-read-only? b d*)) (values b #f)]
    [else
     (define-values (ot* mt*)
       (overlay-table-apply-edit (buffer-overlays b) (buffer-markers b) d*))
     (define props* (properties-apply-edit (buffer-properties b) d*))
     (values (buffer content* mt* props* ot*
                     (add1 (buffer-tick b)))
             d*)]))

(define (buffer-apply-edit b d) (buffer-apply-edit* b d #t))
(define (buffer-apply-edit-trusted b d) (buffer-apply-edit* b d #f))

;; buffer 层的编辑入口：给位置与 op（buffer selection → desc/#f），算 desc 再施加。
(define (buffer-edit b p op [guard? #t])
  (define d (op b (selection p p)))
  (if d
      (buffer-apply-edit* b d guard?)
      (values b #f)))

;;; ---------- 编辑动作（可传的值）----------
;; 形状统一：op : buffer selection → (or/c #f edit-desc)。op 只**算** desc，不施加。
;; 空选区 = 普通光标（anchor=head）；非空选区 = 替换该区间。

(define (edit-insert text)
  (lambda (_b sel) (edit-desc (selection-anchor sel) (selection-head sel) text)))
(define (edit-insert-char ch) (edit-insert (string ch)))
(define (edit-newline)       (edit-insert "\n"))
(define (edit-backspace)
  (lambda (b sel)
    (if (caret? sel)
        (content-backspace-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
(define (edit-delete)
  (lambda (b sel)
    (if (caret? sel)
        (content-delete-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
;; 通用逃生门：显式区间的替换（程序化编辑）
(define (edit-splice start end text) (lambda (_b _sel) (edit-desc start end text)))

;;; ---------- 逆编辑 / 取区间文本 ----------

(define (buffer-range-text b s e)
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (cond
    [(= sl el) (substring (buffer-line-ref b sl) sc ec)]
    [else
     (string-join
      (append (list (substring (buffer-line-ref b sl) sc
                               (string-length (buffer-line-ref b sl))))
              (for/list ([l (in-range (add1 sl) el)]) (buffer-line-ref b l))
              (list (substring (buffer-line-ref b el) 0 ec)))
      "\n")]))

;; 用「编辑前的 buffer」取回 d 删掉的文本，求逆。
;; b 必须是 d 生效前的那一刻（不可变快照，留引用即可）。
(define (buffer-edit-desc-inverse b d)
  (edit-desc-inverse d (buffer-range-text b (edit-desc-start d) (edit-desc-end d))))

;;; ---------- 属性 ----------

;; 把区间 [start,end) 夹到合法域：两端先各自夹紧，再要求**同一行**。
;; 属性是行内区间；跨行没有唯一合法解释 → 报错（与 patch 越界即错同一态度）。
(define (clamp-prop-range who b start end)
  (define s (buffer-clamp-point b start))
  (define e (buffer-clamp-point b end))
  (unless (= (point-line s) (point-line e))
    (error who "属性区间必须在同一行内: ~a..~a" start end))
  (values (point-line s) (point-col s) (point-col e)))

;; 标注/标记/装饰写回：只涨 tick（重绘），不是文本编辑。
(define (bump b) (struct-copy buffer b [tick (add1 (buffer-tick b))]))

(define (buffer-put-property b start end key val)
  (define-values (l s e) (clamp-prop-range 'buffer-put-property b start end))
  (bump (struct-copy buffer b
           [properties (properties-put (buffer-properties b) l s e key val)])))

;; 单点查询收 point（区间查询收两端 point）。
(define (buffer-get-property b p key)
  (properties-get (buffer-properties b) (point-line p) (point-col p) key))

(define (buffer-remove-property b start end key)
  (define-values (l s e) (clamp-prop-range 'buffer-remove-property b start end))
  (bump (struct-copy buffer b
           [properties (properties-remove (buffer-properties b) l s e key)])))

;; segs = (listof (list start end key val))，两端皆为 point；一次 tick。
(define (buffer-put-properties-many b segs)
  (cond
    [(null? segs) b]
    [else
     (define clamped
       (for/list ([sg (in-list segs)])
         (define-values (l s e) (clamp-prop-range 'buffer-put-properties-many b (car sg) (cadr sg)))
         (list* l s e (cddr sg))))
     (bump (struct-copy buffer b
              [properties (properties-put-many (buffer-properties b) clamped)]))]))

;; 写约束槽（传 (make-restrict) 即清除）。只动约束，不碰表现层。
(define (buffer-put-restrict b start end rs)
  (define-values (l s e) (clamp-prop-range 'buffer-put-restrict b start end))
  (bump (struct-copy buffer b
           [properties (properties-put-restrict (buffer-properties b) l s e rs)])))

;; 清约束（= put-restrict 传空）。与 buffer-remove-property 对称。
(define (buffer-remove-restrict b start end)
  (buffer-put-restrict b start end (make-restrict)))

;;; ---------- marker ----------

(define (check-buffer-position who b p)
  (define n (buffer-line-count b))
  (define l (point-line p)) (define c (point-col p))
  (define len (and (exact-nonnegative-integer? l) (< l n)
                   (string-length (buffer-line-ref b l))))
  (unless (and len (exact-nonnegative-integer? c) (<= c len))
    (error who "位置不在 buffer 内: ~a（共 ~a 行）" p n)))

(define (buffer-add-marker b p [insertion-type 'before])
  (check-buffer-position 'buffer-add-marker b p)
  (define-values (mt id) (marker-table-add (buffer-markers b) p insertion-type))
  (values (bump (struct-copy buffer b [markers mt])) id))

(define (buffer-remove-marker b id)
  (bump (struct-copy buffer b [markers (marker-table-remove (buffer-markers b) id)])))

(define (buffer-marker-pos b id)
  (define m (marker-table-get (buffer-markers b) id))
  (and m (marker-pos m)))

;;; ---------- overlay ----------

(define (buffer-add-overlay b start end [presentation (hash)]
                            #:priority [priority 0]
                            #:evaporate? [evaporate? #f])
  (check-buffer-position 'buffer-add-overlay b start)
  (check-buffer-position 'buffer-add-overlay b end)
  (when (point<? end start)
    (error 'buffer-add-overlay "overlay 区间反向: ~a..~a" start end))
  (define-values (mt1 sid) (marker-table-add (buffer-markers b) start 'before))
  (define-values (mt2 eid) (marker-table-add mt1 end 'after))
  (define-values (ot oid)
    (overlay-table-add (buffer-overlays b) sid eid presentation
                       #:priority priority #:evaporate? evaporate?))
  (values (bump (struct-copy buffer b [markers mt2] [overlays ot])) oid))

(define (buffer-remove-overlay b oid)
  (bump (struct-copy buffer b [overlays (overlay-table-remove (buffer-overlays b) oid)])))

;; 读回：覆盖 p 的 overlay（priority 降序）/ 某行的 overlay 段。与 add/remove 对称。
(define (buffer-overlay-at b p)
  (overlay-table-at (buffer-overlays b) (buffer-markers b) p))
(define (buffer-overlay-runs b line)
  (overlay-table-runs (buffer-overlays b) (buffer-markers b) line
                      (string-length (buffer-line-ref b line))))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))

  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines b0) '("hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-tick b0) 0)

  ;; 位置解析（不依赖光标）：行长度 / 夹紧 / 行列 ↔ 偏移
  (check-equal? (buffer-line-length b0 0) 5)
  (check-equal? (buffer-line-length b0 99) 5)
  (check-equal? (buffer-clamp-point b0 (point 9 9)) (point 1 5))
  (check-equal? (buffer-point->offset b0 (point 1 0)) 6)
  (check-equal? (buffer-offset->point b0 11) (point 1 5))

  ;; 编辑入口：buffer-edit + 可传的 op
  (define-values (b1 d1) (buffer-edit b0 (point 0 0) (edit-insert-char #\X)))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? d1 (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (buffer-tick b1) 1)

  ;; 换行 / 退格合并 / 前向删除
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 0 5) (edit-newline))]) b))
                "hello\n\nworld")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 1 0) (edit-backspace))]) b))
                "helloworld")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 0 5) (edit-delete))]) b))
                "helloworld")

  ;; 无操作 → desc #f、buffer 原样
  (define-values (b-nop d-nop) (buffer-edit b0 (point 0 0) (edit-backspace)))
  (check-eq? b-nop b0)
  (check-false d-nop)

  ;; buffer-apply-edit 与产生该 desc 的编辑等价
  (define-values (b2 _d2) (buffer-apply-edit b0 (edit-desc (point 0 1) (point 0 1) "XY")))
  (check-equal? (buffer->string b2) "hXYello\nworld")

  ;; 属性：随编辑移动 + 插入继承
  (define b3 (buffer-put-property b0 (point 0 1) (point 0 4) 'face 'bold))
  (check-equal? (buffer-get-property b3 (point 0 2) 'face) 'bold)
  (define-values (b4 _d4) (buffer-edit b3 (point 0 2) (edit-insert-char #\Z)))
  (check-equal? (buffer->string b4) "heZllo\nworld")
  (check-equal? (buffer-get-property b4 (point 0 2) 'face) 'bold)   ; 新字符继承
  (check-false (buffer-get-property (buffer-remove-property b3 (point 0 1) (point 0 4) 'face)
                                    (point 0 2) 'face))
  ;; 区间跨行 → 报错（属性是行内区间）
  (check-exn exn:fail?
             (lambda () (buffer-put-property b0 (point 0 0) (point 1 0) 'face 'bold)))

  ;; read-only 守卫：区间内部插入被拒；右端点允许且不继承
  (define rb (buffer-put-restrict b0 (point 0 1) (point 0 4) (restrict #t)))
  (check-true (restrict-read-only? (buffer-restrict-at rb (point 0 2))))
  (define-values (rb1 rd1) (buffer-edit rb (point 0 2) (edit-insert-char #\X)))
  (check-eq? rb1 rb)
  (check-false rd1)
  (define-values (rb2 _rd2) (buffer-edit rb (point 0 4) (edit-insert-char #\X)))
  (check-equal? (buffer->string rb2) "hellXo\nworld")
  (check-false (restrict-read-only? (buffer-restrict-at rb2 (point 0 4))))
  ;; 删除跨进 read-only → 拒绝
  (define-values (rb3 rd3) (buffer-edit rb (point 0 4) (edit-backspace)))
  (check-eq? rb3 rb)
  (check-false rd3)
  ;; trusted 入口：程序编辑 read-only
  (define-values (rb4 rd4) (buffer-edit rb (point 0 2) (edit-insert-char #\X) #f))
  (check-equal? (buffer->string rb4) "heXllo\nworld")
  (check-equal? rd4 (edit-desc (point 0 2) (point 0 2) "X"))

  ;; 枚举只读段
  (check-equal? (buffer-restrict-runs rb 0)
                (list (list 0 1 (make-restrict)) (list 1 4 (restrict #t)) (list 4 5 (make-restrict))))
  ;; 读回约束槽 / 清约束（与 put-restrict 对称）
  (check-equal? (buffer-restrict-at rb (point 0 2)) (restrict #t))
  (define rb-nr (buffer-remove-restrict rb (point 0 1) (point 0 4)))
  (check-false (restrict-read-only? (buffer-restrict-at rb-nr (point 0 2))))
  (check-equal? (buffer-restrict-runs rb-nr 0) (list (list 0 5 (make-restrict))))

  ;; marker：随编辑移动
  (define-values (mb mid) (buffer-add-marker b0 (point 0 3)))
  (define mb2 (let-values ([(b _) (buffer-edit mb (point 0 0) (edit-insert-char #\a))]) b))
  (check-equal? (buffer-marker-pos mb2 mid) (point 0 4))
  (check-equal? (buffer-marker-pos (buffer-remove-marker mb2 mid) mid) #f)

  ;; overlay：随编辑移动 + evaporate
  (define-values (ob oid) (buffer-add-overlay b0 (point 0 1) (point 0 4) (hash 'face 'region)))
  (define ob2 (let-values ([(b _) (buffer-edit ob (point 0 0) (edit-insert-char #\a))]) b))
  (define oruns (overlay-table-runs (buffer-overlays ob2) (buffer-markers ob2) 0 10))
  (check-equal? (list (caar oruns) (cadar oruns)) '(2 5))
  ;; 读回（与 add/remove-overlay 对称）
  (check-equal? (length (buffer-overlay-at ob2 (point 0 2))) 1)
  (check-equal? (length (buffer-overlay-at ob2 (point 0 0))) 0)
  (check-equal? (list (caar (buffer-overlay-runs ob2 0)) (cadar (buffer-overlay-runs ob2 0))) '(2 5))
  (define-values (ob3 _oid3) (buffer-add-overlay b0 (point 0 1) (point 0 3) (hash)
                                             #:evaporate? #t))
  (define ob4 (let-values ([(b _) (buffer-edit ob3 (point 0 1) (edit-delete))]) b))
  (define ob5 (let-values ([(b _) (buffer-edit ob4 (point 0 1) (edit-delete))]) b))
  (check-equal? (overlay-table-count (buffer-overlays ob5)) 0)

  ;; 逆编辑：用编辑前的 buffer 取回被删文本
  (define u0 (buffer-open "abcd\nefgh"))
  (define-values (u1 du1) (buffer-edit u0 (point 0 1) (edit-insert "XY\nZ")))
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit u1 (buffer-edit-desc-inverse u0 du1))]) b))
                "abcd\nefgh")
  (define-values (u2 du2) (buffer-apply-edit u0 (edit-desc (point 0 1) (point 1 2) "")))
  (check-equal? (buffer->string u2) "agh")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit u2 (buffer-edit-desc-inverse u0 du2))]) b))
                "abcd\nefgh")

  ;; 事后加 read-only：守卫版拒绝逆，trusted 版生效（撤销语义）
  (define v0 (buffer-open "hello"))
  (define-values (v1 vd) (buffer-edit v0 (point 0 1) (edit-insert "X")))
  (define vinv (buffer-edit-desc-inverse v0 vd))
  (define vr (buffer-put-restrict v1 (point 0 1) (point 0 2) (restrict #t)))
  (check-eq? (let-values ([(b _) (buffer-apply-edit vr vinv)]) b) vr)
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit-trusted vr vinv)]) b)) "hello")

  ;; 反向区间 → 报错
  (check-exn exn:fail?
             (lambda () (buffer-apply-edit (buffer-open "abcdef")
                                           (edit-desc (point 0 3) (point 0 1) ""))))

  (displayln "buffer.rkt: all tests passed"))
