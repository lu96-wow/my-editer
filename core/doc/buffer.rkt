#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/selection.rkt" "../atom/attr.rkt" "../atom/change.rkt"
         "../unit/attrs.rkt" racket/match racket/list rackunit)

;;; doc/buffer.rkt —— 文档：文本 + 属性（无光标、无 face 存储）
;;;
;;; 装配根。把「文本 buffer（content）」与「属性 buffer（attrs）」绑成一个值。
;;;
;;; 唯一变更漏斗是 **buffer-apply-change**：吃一个 change（文本 descs + 属性 descs），
;;; 一次性把两部分都施加，返回新 buffer + change-result（含撤销材料）。
;;;
;;;   buffer-apply-change         带 read-only 守卫
;;;   buffer-apply-change-trusted 跳守卫（撤销/重放/格式化）
;;;   buffer-apply-edit[-trusted] 文本单条的便利封装
;;;   buffer-put-attr/remove-attr 属性单条的便利封装（内部走 change）
;;;
;;; **文本是唯一权威**：content-apply 先夹紧/校验并产出**生效 desc**；attrs 只吃这条
;;; 生效 desc（不做任何校验），于是两个单元用同一套编辑运算、各自封装细节。
;;;
;;; core 只解释一个保留 key：'read-only（守卫）。其余 key 对 core 不透明，随编辑移动。
;;; 派生 face 不入库：走投影时的 face-provider（viewport/render.rkt）。
;;;
;;; 编辑传播顺序（唯一）：
;;;   content-apply（夹紧 + 生效文本 desc）
;;;   → 守卫
;;;   → attrs-apply-edit（属性跟随；同时捕获被抹掉的属性，供撤销补回）
;;;   → attrs-apply-attr-batch（显式属性变更，坐标 = 文本生效之后）

(provide
 buffer?                            ; 构造器/内部字段不外露（避免绕过不变量）
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
 buffer-edit-trusted
 ;; 变更漏斗（文本 + 属性）
 buffer-apply-change
 buffer-apply-change-trusted
 change-result
 change-result?
 change-result-applied-texts
 change-result-applied-attrs
 change-result-text-inverses
 change-result-attr-inverses
 change-result-erased-restores
 change-result-replay
 change-result-undo
 ;; 文本动作
 buffer-op-insert-char
 buffer-op-insert
 buffer-op-newline
 buffer-op-backspace
 buffer-op-delete
 buffer-op-splice
 buffer-edit-desc-inverse
 buffer-range-text
 buffer-clamp-edit-descs
 ;; 属性读写（通用 key→value）
 read-only-key
 attr-read-only?
 buffer-attr-at
 buffer-attr-runs
 buffer-attr-key-runs
 buffer-put-attr
 buffer-remove-attr
 buffer-tick
 buffer-content-eq?)

;;; ---------- 数据 ----------

(struct buffer
  (content ; content.rkt
   attrs   ; attrs（属性 buffer：通用 key→value）
   tick)   ; nat      任何改动 +1（编辑 / 写属性）
  #:transparent)

;; 一次 change 的完整结果：生效 descs + 撤销材料。命令返回 report 用它现算。
(struct change-result
  (applied-texts    ; (listof edit-desc)   施加顺序（起点倒序）
   applied-attrs    ; (listof attr-desc)   施加顺序
   text-inverses    ; 与 applied-texts 平行
   attr-inverses    ; (listof (listof attr-desc))；与 applied-attrs 平行
   erased-restores) ; (listof attr-desc)   原坐标：补回被文本编辑抹掉的属性
  #:transparent)

;;; ---------- 构造 / 投影 ----------

(define (buffer-open s)
  (define c (content-of-string s))
  (buffer c (attrs-empty (content-line-count c)) 0))

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines b)  (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))
(define (buffer-line-length b i) (content-line-length (buffer-content b) i))
;; 位置解析只取决于 buffer（content），与任何 window/光标无关。
(define (buffer-clamp-point b p) (content-clamp-point (buffer-content b) p))
(define (buffer-point->offset b p) (content-point->offset (buffer-content b) p))
(define (buffer-offset->point b off) (content-offset->point (buffer-content b) off))

;; 内容是否同一：只有 splice 才换新 content（不可变 struct），写属性不改 content。
;; 这是「用户改了内容」与「只写了属性」的精确区分。
(define (buffer-content-eq? a b) (eq? (buffer-content a) (buffer-content b)))

;;; ---------- 属性读写 ----------

;; core 保留 key：read-only。core 只解释它，其余对 core 不透明。
(define read-only-key 'read-only)
(define (attr-read-only? h) (eq? #t (hash-ref h read-only-key #f)))

;; 某点的全部属性（hash）。位置先按 content 夹紧。
(define (buffer-attr-at b p)
  (define q (buffer-clamp-point b p))
  (attrs-at (buffer-attrs b) q))

;; 一行内属性段：(listof (list start end hash))，恰好覆盖整行。
(define (buffer-attr-runs b line)
  (attrs-runs (buffer-attrs b) line (string-length (buffer-line-ref b line))))

;; 一行内某个 key 的段：(listof (list start end val))。
(define (buffer-attr-key-runs b line key)
  (attrs-key-runs (buffer-attrs b) line (string-length (buffer-line-ref b line)) key))

;; 写属性只涨 tick（重绘），不是文本编辑。走 change 漏斗，因此守 read-only 语义一致。
(define (buffer-put-attr b start end key val)
  (define-values (b* _) (buffer-apply-change b (change/attrs (list (attr-set start end key val)))))
  b*)
(define (buffer-remove-attr b start end key)
  (define-values (b* _) (buffer-apply-change b (change/attrs (list (attr-del start end key)))))
  b*)

;;; ---------- read-only 守卫 ----------
;; 规则（显式契约）：
;;   · 零宽插入：插入点落在只读区间的半开跨度 [start,end) 内 → 拒绝（右端点允许）
;;   · 非零宽删除：删除区间 [s,e) 与任一 read-only 段有交集 → 拒绝
;; 程序要编辑 read-only 内容，走显式入口 buffer-apply-change-trusted。

(define (line-range-read-only? b line a z)
  (for/or ([seg (in-list (buffer-attr-runs b line))])
    (match-define (list s e h) seg)
    (and (attr-read-only? h) (< (max a s) (min z e)))))

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
      (attr-read-only? (buffer-attr-at b s))
      (range-read-only? b s e)))

;;; ---------- 内部：低层施加（不含 tick） ----------

(define (bump b) (struct-copy buffer b [tick (add1 (buffer-tick b))]))

;; 施加一条文本 desc 到 content+attrs；tick 保持不变。
;; 返回 (values 新 buffer（可能同值） 生效 desc / #f)。
(define (apply-text-desc b d guard?)
  (define-values (content* d*) (content-apply (buffer-content b) d))
  (cond
    [(and guard? (desc-read-only? b d*)) (values b #f)]
    [else
     (define at* (attrs-apply-edit (buffer-attrs b) d*))
     (values (buffer content* at* (buffer-tick b)) d*)]))

;;; ---------- 文本编辑：单条 / 批量（tick +1） ----------

(define (buffer-apply-edit b d) (buffer-apply-edit* b d #t))
(define (buffer-apply-edit-trusted b d) (buffer-apply-edit* b d #f))
(define (buffer-apply-edit* b d guard?)
  (define-values (b* d*) (apply-text-desc b d guard?))
  (if d* (values (bump b*) d*) (values b #f)))

;; buffer 层的编辑入口：给位置与 op（buffer selection → desc/#f），算 desc 再施加。
(define (buffer-edit b p op) (buffer-edit* b p op #t))
(define (buffer-edit-trusted b p op) (buffer-edit* b p op #f))
(define (buffer-edit* b p op guard?)
  (define d (op b (selection p p)))
  (if d
      (buffer-apply-edit* b d guard?)
      (values b #f)))

;;; ---------- 唯一变更漏斗：change ----------

;; change 的属性坐标 = 文本生效之后；逐条夹到生效 content 的行/列域。
(define (clamp-attr-desc content d)
  (define s (attr-desc-start d)) (define e (attr-desc-end d))
  (unless (= (point-line s) (point-line e))
    (error 'buffer-apply-change "属性区间必须同一行: ~a..~a" s e))
  (define l (point-line s))
  (when (>= l (content-line-count content))
    (error 'buffer-apply-change "属性行号越界: ~a（content 行数 ~a）"
           l (content-line-count content)))
  (define len (content-line-length content l))
  (define s* (point l (min (max 0 (point-col s)) len)))
  (define e* (point l (min (max 0 (point-col e)) len)))
  (when (point<? e* s*)
    (error 'buffer-apply-change "属性区间反向: ~a..~a" s* e*))
  (attr-desc s* e* (attr-desc-key d) (attr-desc-op d) (attr-desc-val d)))

;; 把 attrs-range-runs 的 (line a b hash) 展开成每条 key 一条 attr-set。
(define (runs->attr-descs runs)
  (append*
   (for/list ([r (in-list runs)])
     (match-define (list line x y h) r)
     (for/list ([(k v) (in-hash h)])
       (attr-set (point line x) (point line y) k v)))))

;; 文本批：规范化（排序 + 重叠检查）→ 按起点倒序施加 → attrs 跟随 → 捕获被抹属性。
;; tick 不变。返回 (values buffer applied-texts text-inverses erased-restores)，
;; applied/inverses 为施加顺序。
(define (apply-text-batch b descs guard?)
  (define ordered (edits-normalize 'buffer-apply-change descs))
  (define-values (b* applied invs erased)
    (for/fold ([b b] [applied '()] [invs '()] [erased '()])
              ([d (in-list (reverse ordered))])
      (define b-before b)
      (define-values (bb dd) (apply-text-desc b d guard?))
      (cond
        [(not dd) (values bb applied invs erased)]
        [else
         (define er (runs->attr-descs
                     (attrs-range-runs (buffer-attrs b-before)
                                       (edit-desc-start dd) (edit-desc-end dd))))
         (values bb (cons dd applied)
                 (cons (buffer-edit-desc-inverse b-before dd) invs)
                 (append erased er))])))
  (values b* (reverse applied) (reverse invs) erased))

(define (buffer-apply-change b ch) (buffer-apply-change* b ch #t))
(define (buffer-apply-change-trusted b ch) (buffer-apply-change* b ch #f))
(define (buffer-apply-change* b ch guard?)
  (define-values (b1 applied-texts text-invs erased)
    (apply-text-batch b (change-texts ch) guard?))
  (define eff-attrs
    (filter-map (lambda (d)
                  (define d* (clamp-attr-desc (buffer-content b1) d))
                  (and (not (attr-desc-empty? d*)) d*))
                (change-attrs ch)))
  (define attr-invs (map (lambda (d) (attrs-attr-inverse (buffer-attrs b1) d)) eff-attrs))
  (define attrs* (attrs-apply-attr-batch (buffer-attrs b1) 'buffer-apply-change eff-attrs))
  (cond
    [(and (null? applied-texts) (null? eff-attrs)) (values b #f)]
    [else
     (define b* (buffer (buffer-content b1) attrs* (add1 (buffer-tick b))))
     (values b* (change-result applied-texts eff-attrs text-invs attr-invs erased))]))

;; 由结果构造「重放 / 撤销」两个值：
;;   replay：生效文本批 + 其后的属性
;;   undo  ：依次为「属性逆」「文本逆」「被抹属性补回」（均为 change，依次施加）
(define (change-result-replay res)
  (change (change-result-applied-texts res) (change-result-applied-attrs res)))
(define (change-result-undo res)
  (append
   ;; ① 显式属性的逆：同一（post）坐标，可批
   (list (change/attrs (append* (reverse (change-result-attr-inverses res)))))
   ;; ② 文本逆：与 applied 平行，每条坐标基于「上一条之后」——
   ;;    必须**逆序、逐条**作为独立 change 施加，不能当同一坐标批处理。
   (for/list ([d (in-list (reverse (change-result-text-inverses res)))])
     (change/edits (list d)))
   ;; ③ 被抹掉的属性：此时 content 已复原，用原坐标补回
   (list (change/attrs (change-result-erased-restores res)))))

;; 把一串文本 desc 夹到生效域（不动 buffer）；供上层在算属性计划前看到真实落点。
(define (buffer-clamp-edit-descs b descs)
  (map (lambda (d) (content-clamp-desc (buffer-content b) d)) descs))

;;; ---------- 编辑动作（buffer 级，可传的值）----------
;;; 形状统一：op : buffer selection → (or/c #f edit-desc)。op 只**算** desc，不施加。

(define (buffer-op-insert text)
  (lambda (_b sel) (edit-desc (selection-anchor sel) (selection-head sel) text)))
(define (buffer-op-insert-char ch) (buffer-op-insert (string ch)))
(define (buffer-op-newline)       (buffer-op-insert "\n"))
(define (buffer-op-backspace)
  (lambda (b sel)
    (if (caret? sel)
        (content-backspace-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
(define (buffer-op-delete)
  (lambda (b sel)
    (if (caret? sel)
        (content-delete-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
;; 通用逃生门：显式区间的替换（程序化编辑）
(define (buffer-op-splice start end text) (lambda (_b _sel) (edit-desc start end text)))

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
(define (buffer-edit-desc-inverse b d)
  (edit-desc-inverse d (buffer-range-text b (edit-desc-start d) (edit-desc-end d))))

;;; ---------- 测试 ----------

(module+ test
  (define P (lambda (l c) (point l c)))
  (define b0 (buffer-open "hello\nworld"))
  (define ro (hash read-only-key #t))

  ;; 构造 + 投影
  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines b0) '("hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-tick b0) 0)
  (check-true (buffer-content-eq? b0 b0))
  (check-equal? (buffer-line-length b0 0) 5)
  (check-equal? (buffer-line-length b0 99) 5)
  (check-equal? (buffer-clamp-point b0 (point 9 9)) (point 1 5))
  (check-equal? (buffer-point->offset b0 (point 1 0)) 6)
  (check-equal? (buffer-offset->point b0 11) (point 1 5))

  ;; 编辑入口
  (define-values (b1 d1) (buffer-edit b0 (point 0 0) (buffer-op-insert-char #\X)))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? d1 (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (buffer-tick b1) 1)
  (check-false (buffer-content-eq? b0 b1))

  ;; 换行 / 退格合并 / 前向删除
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 0 5) (buffer-op-newline))]) b))
                "hello\n\nworld")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 1 0) (buffer-op-backspace))]) b))
                "helloworld")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-edit b0 (point 0 5) (buffer-op-delete))]) b))
                "helloworld")

  ;; 无操作 → desc #f、buffer 原样
  (define-values (b-nop d-nop) (buffer-edit b0 (point 0 0) (buffer-op-backspace)))
  (check-eq? b-nop b0)
  (check-false d-nop)

  ;; 属性读写：任意 key 独立；read-only 是保留 key
  (define ab (buffer-put-attr b0 (point 0 1) (point 0 4) 'face 'bold))
  (check-equal? (buffer-attr-at ab (point 0 2)) (hash 'face 'bold))
  (check-equal? (buffer-attr-key-runs ab 0 'face) (list (list 1 4 'bold)))
  (define ab2 (buffer-put-attr ab (point 0 2) (point 0 3) read-only-key #t))
  (check-equal? (buffer-attr-at ab2 (point 0 2)) (hash 'face 'bold read-only-key #t))
  (check-equal? (buffer-attr-key-runs ab2 0 read-only-key) (list (list 2 3 #t)))
  (define ab3 (buffer-remove-attr ab2 (point 0 2) (point 0 3) read-only-key))
  (check-false (attr-read-only? (buffer-attr-at ab3 (point 0 2))))
  (check-true (buffer-content-eq? b0 ab))          ; 写属性不动 content
  (check-equal? (buffer-tick b0) 0)                ; ab 是另一个值，b0 的 tick 不变

  ;; 零宽属性 = no-op（不再报错）
  (check-eq? (buffer-put-attr b0 (point 0 1) (point 0 1) 'k #t) b0)
  (check-eq? (buffer-remove-attr ab (point 0 2) (point 0 2) 'face) ab)
  ;; 跨行属性 → 报错（先判同行，再夹列）
  (check-exn exn:fail? (lambda () (buffer-put-attr b0 (point 0 0) (point 1 0) 'k #t)))
  ;; 越界行 → 具名报错，不是 vector-ref 崩
  (check-exn exn:fail? (lambda () (buffer-put-attr b0 (point 9 0) (point 9 1) 'k #t)))

  ;; read-only 守卫：区间内部插入被拒；右端点允许且不继承
  (define rb (buffer-put-attr b0 (point 0 1) (point 0 4) read-only-key #t))
  (check-true (attr-read-only? (buffer-attr-at rb (point 0 2))))
  (define-values (rb1 rd1) (buffer-edit rb (point 0 2) (buffer-op-insert-char #\X)))
  (check-eq? rb1 rb)
  (check-false rd1)
  (define-values (rb2 _rd2) (buffer-edit rb (point 0 4) (buffer-op-insert-char #\X)))
  (check-equal? (buffer->string rb2) "hellXo\nworld")
  (check-false (attr-read-only? (buffer-attr-at rb2 (point 0 4))))
  (define-values (rb3 rd3) (buffer-edit rb (point 0 4) (buffer-op-backspace)))
  (check-eq? rb3 rb)
  (check-false rd3)
  (define-values (rb4 rd4) (buffer-edit-trusted rb (point 0 2) (buffer-op-insert-char #\X)))
  (check-equal? (buffer->string rb4) "heXllo\nworld")
  (check-equal? rd4 (edit-desc (point 0 2) (point 0 2) "X"))

  ;; 枚举属性段 / 清属性
  (check-equal? (buffer-attr-runs rb 0)
                (list (list 0 1 (hash)) (list 1 4 ro) (list 4 5 (hash))))
  (define rb-nr (buffer-remove-attr rb (point 0 1) (point 0 4) read-only-key))
  (check-false (attr-read-only? (buffer-attr-at rb-nr (point 0 2))))
  (check-equal? (buffer-attr-runs rb-nr 0) (list (list 0 5 (hash))))

  ;; 逆编辑
  (define u0 (buffer-open "abcd\nefgh"))
  (define-values (u1 du1) (buffer-edit u0 (point 0 1) (buffer-op-insert "XY\nZ")))
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit u1 (buffer-edit-desc-inverse u0 du1))]) b))
                "abcd\nefgh")
  (define-values (u2 du2) (buffer-apply-edit u0 (edit-desc (point 0 1) (point 1 2) "")))
  (check-equal? (buffer->string u2) "agh")
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit u2 (buffer-edit-desc-inverse u0 du2))]) b))
                "abcd\nefgh")

  ;; 事后加 read-only：守卫版拒绝逆，trusted 版生效（撤销语义）
  (define v0 (buffer-open "hello"))
  (define-values (v1 vd) (buffer-edit v0 (point 0 1) (buffer-op-insert "X")))
  (define vinv (buffer-edit-desc-inverse v0 vd))
  (define vr (buffer-put-attr v1 (point 0 1) (point 0 2) read-only-key #t))
  (check-eq? (let-values ([(b _) (buffer-apply-edit vr vinv)]) b) vr)
  (check-equal? (buffer->string (let-values ([(b _) (buffer-apply-edit-trusted vr vinv)]) b)) "hello")

  ;; 反向区间 → 报错
  (check-exn exn:fail?
             (lambda () (buffer-apply-edit (buffer-open "abcdef")
                                           (edit-desc (point 0 3) (point 0 1) ""))))

  ;; ---- change：文本 + 属性一步施加 ----
  (define cb0 (buffer-open "abc"))
  (define-values (cb1 res)
    (buffer-apply-change cb0
      (change (list (edit-desc (point 0 1) (point 0 1) "X"))
              (list (attr-set (point 0 1) (point 0 2) read-only-key #t)))))
  (check-equal? (buffer->string cb1) "aXbc")
  (check-equal? (buffer-attr-key-runs cb1 0 read-only-key) (list (list 1 2 #t)))
  (check-equal? (buffer-tick cb1) 1)                     ; 一次 change 一次 tick
  (check-equal? (change-result-applied-texts res) (list (edit-desc (point 0 1) (point 0 1) "X")))
  (check-equal? (change-result-applied-attrs res)
                (list (attr-set (point 0 1) (point 0 2) read-only-key #t)))

  ;; 撤销辅助：用 change-result-undo 构造撤销序列
  (define (apply-undo b res)
    (for/fold ([x b]) ([c (in-list (change-result-undo res))])
      (let-values ([(x* _) (buffer-apply-change-trusted x c)]) x*)))
  (check-equal? (change-result-replay res)
                (change (list (edit-desc (point 0 1) (point 0 1) "X"))
                        (list (attr-set (point 0 1) (point 0 2) read-only-key #t))))

  ;; 文本+属性 → 撤销回到原样
  (define cb2 (apply-undo cb1 res))
  (check-equal? (buffer->string cb2) "abc")
  (check-false (attr-read-only? (buffer-attr-at cb2 (point 0 1))))

  ;; 关键回归：删除带属性的文本，撤销必须把属性一起带回（旧实现会丢）
  (define eb0 (buffer-put-attr (buffer-open "abc") (point 0 0) (point 0 3) read-only-key #t))
  (define-values (eb1 res2)
    (buffer-apply-change-trusted eb0 (change/edits (list (edit-desc (point 0 1) (point 0 2) "")))))
  (check-equal? (buffer->string eb1) "ac")
  (check-equal? (buffer-attr-key-runs eb1 0 read-only-key) (list (list 0 2 #t)))
  (define eb2 (apply-undo eb1 res2))
  (check-equal? (buffer->string eb2) "abc")
  (check-equal? (buffer-attr-key-runs eb2 0 read-only-key) (list (list 0 3 #t)))   ; 属性回来了

  ;; 守卫：change 里文本被拒 → 只有属性生效？不——文本被拒则该条文本不进结果，
  ;; 但属性仍按声明的（文本生效后）坐标施加；这里属性落在 (0,1) 合法区间。
  (define gb (buffer-open "abc"))
  (define rbc (buffer-put-attr gb (point 0 0) (point 0 1) read-only-key #t))
  (define-values (gb1 res3)
    (buffer-apply-change rbc (change/edits (list (edit-desc (point 0 0) (point 0 0) "Z")))))
  (check-equal? (buffer->string gb1) "abc")              ; 只读内插入被拒
  (check-false res3)

  (displayln "buffer.rkt: all tests passed"))
