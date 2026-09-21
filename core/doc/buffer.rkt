#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/selection.rkt"
         "../unit/attrs.rkt" rackunit)

;;; doc/buffer.rkt —— 文档：文本 + 属性（无光标、无 face 存储）
;;;
;;; 装配根。把「文本 buffer（content）」与「属性 buffer（attrs）」绑成一个值：
;;;
;;;   buffer-apply-edit b desc           过一次编辑：content 产出生效 desc，attrs 跟随
;;;   buffer-apply-edit-trusted b desc   同上，跳过 read-only 守卫（撤销/重放用）
;;;   buffer-edit b point op             算一条 desc（op）再施加，是 buffer 层的编辑入口
;;;
;;; **文本是唯一权威**：content-apply 先夹紧/校验并产出**生效 desc**；attrs 只吃这条
;;; 生效 desc（不做任何校验），于是两个单元用同一套编辑运算、各自封装细节。
;;;
;;; core 只解释一个保留 key：'read-only（守卫）。其余 key 对 core 不透明，随编辑移动。
;;; 派生 face 不入库：走投影时的 face-provider（viewport/render.rkt）。
;;;
;;; 光标不在 buffer 里：一个 buffer 可被多个 window 绑定，各有自己的 point。
;;; 编辑传播顺序（唯一）：content-apply（夹紧 + 有效 desc）→ 守卫 → attrs。

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
 buffer-op-insert-char
 buffer-op-insert
 buffer-op-newline
 buffer-op-backspace
 buffer-op-delete
 buffer-op-splice
 buffer-edit-desc-inverse
 buffer-range-text
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
  (attrs-at (buffer-attrs b) (point-line q) (point-col q)))

;; 一行内属性段：(listof (list start end hash))，恰好覆盖整行。
(define (buffer-attr-runs b line)
  (attrs-runs (buffer-attrs b) line (string-length (buffer-line-ref b line))))

;; 一行内某个 key 的段：(listof (list start end val))。
(define (buffer-attr-key-runs b line key)
  (attrs-key-runs (buffer-attrs b) line (string-length (buffer-line-ref b line)) key))

;; 把区间 [start,end) 夹到合法域：两端先各自夹紧，再要求**同一行**。
;; 属性是行内区间；跨行没有唯一合法解释 → 报错。
(define (clamp-line-range who b start end)
  (define s (buffer-clamp-point b start))
  (define e (buffer-clamp-point b end))
  (unless (= (point-line s) (point-line e))
    (error who "属性区间必须在同一行内: ~a..~a" start end))
  (values (point-line s) (point-col s) (point-col e)))

;; 写属性只涨 tick（重绘），不是文本编辑。
(define (bump b) (struct-copy buffer b [tick (add1 (buffer-tick b))]))

(define (buffer-put-attr b start end key val)
  (define-values (l s e) (clamp-line-range 'buffer-put-attr b start end))
  (bump (struct-copy buffer b
          [attrs (attrs-put (buffer-attrs b) l s e key val)])))

(define (buffer-remove-attr b start end key)
  (define-values (l s e) (clamp-line-range 'buffer-remove-attr b start end))
  (bump (struct-copy buffer b
          [attrs (attrs-remove (buffer-attrs b) l s e key)])))

;;; ---------- read-only 守卫 ----------
;; 规则（显式契约）：
;;   · 零宽插入：插入点落在只读区间的半开跨度 [start,end) 内 → 拒绝（右端点允许）
;;   · 非零宽删除：删除区间 [s,e) 与任一 read-only 段有交集 → 拒绝
;; 程序要编辑 read-only 内容，走显式入口 buffer-apply-edit-trusted。

;; [a,z) 与某行任一 read-only 段有交集？
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

;;; ---------- 编辑：唯一传播点 ----------

;; 应用一条 edit-desc 到所有层。guard? = #f 时跳过 read-only 守卫。
;; 返回 (values 新 buffer 生效 desc)；被守卫拒绝 → desc = #f。
(define (buffer-apply-edit* b d guard?)
  (define-values (content* d*) (content-apply (buffer-content b) d))
  (cond
    [(and guard? (desc-read-only? b d*)) (values b #f)]
    [else
     (define at* (attrs-apply-edit (buffer-attrs b) d*))
     (values (buffer content* at* (add1 (buffer-tick b)))
             d*)]))

(define (buffer-apply-edit b d) (buffer-apply-edit* b d #t))
(define (buffer-apply-edit-trusted b d) (buffer-apply-edit* b d #f))

;; buffer 层的编辑入口：给位置与 op（buffer selection → desc/#f），算 desc 再施加。
(define (buffer-edit b p op) (buffer-edit* b p op #t))
(define (buffer-edit-trusted b p op) (buffer-edit* b p op #f))
(define (buffer-edit* b p op guard?)
  (define d (op b (selection p p)))
  (if d
      (buffer-apply-edit* b d guard?)
      (values b #f)))

;;; ---------- 编辑动作（buffer 级，可传的值）----------
;;; 形状统一：op : buffer selection → (or/c #f edit-desc)。op 只**算** desc，不施加。
;;; editor 级动作（app 用）在 platform/program.rkt，叫 edit-*，转发给这些。

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
  (define b0 (buffer-open "hello\nworld"))
  (define ro (hash read-only-key #t))

  ;; 构造 + 投影（文本 / 行 / 行数 / tick / content 同一性）
  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines b0) '("hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-tick b0) 0)
  (check-true (buffer-content-eq? b0 b0))

  ;; 位置解析
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
  ;; 写属性不动 content
  (check-true (buffer-content-eq? b0 ab))

  ;; read-only 守卫：区间内部插入被拒；右端点允许且不继承
  (define rb (buffer-put-attr b0 (point 0 1) (point 0 4) read-only-key #t))
  (check-true (attr-read-only? (buffer-attr-at rb (point 0 2))))
  (define-values (rb1 rd1) (buffer-edit rb (point 0 2) (buffer-op-insert-char #\X)))
  (check-eq? rb1 rb)
  (check-false rd1)
  (define-values (rb2 _rd2) (buffer-edit rb (point 0 4) (buffer-op-insert-char #\X)))
  (check-equal? (buffer->string rb2) "hellXo\nworld")
  (check-false (attr-read-only? (buffer-attr-at rb2 (point 0 4))))
  ;; 删除跨进 read-only → 拒绝
  (define-values (rb3 rd3) (buffer-edit rb (point 0 4) (buffer-op-backspace)))
  (check-eq? rb3 rb)
  (check-false rd3)
  ;; trusted 入口：程序编辑 read-only
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

  (displayln "buffer.rkt: all tests passed"))
