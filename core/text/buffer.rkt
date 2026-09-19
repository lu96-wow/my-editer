#lang racket

(require "point.rkt" "content.rkt" "marker.rkt"
         "properties.rkt" "overlay.rkt" rackunit)

;;; buffer.rkt —— 文档：文本 + 元数据（无光标）
;;;
;;; 组合根。所有编辑原语在这里装配：
;;;   1. sync gap 到给定位置 (line, col)
;;;   2. content-edit → (content', desc)
;;;   3. overlay-table-apply-edit ot mt desc → (ot', mt')
;;;      （内部先调 marker-table-apply-edit，再判 evaporate）
;;;   4. properties-apply-edit props desc → props'
;;;   5. 更新 tick / modified?
;;;
;;; 光标（point）不属于文档，属于 window：一个 buffer 可被多个 window 绑定，
;;; 每个 window 有自己的 point。所以本文件的编辑原语都要求显式位置。

(provide
 (struct-out buffer)
 (struct-out edit-desc)
 (struct-out edit-change)
 (struct-out restrict)
 make-restrict
 buffer-open
 buffer->string
 buffer->lines
 buffer-line-count
 buffer-line-ref
 buffer-splice
 buffer-splice-trusted
 buffer-insert-char
 buffer-insert-string
 buffer-newline
 buffer-backspace
 buffer-delete
 edit-char
 edit-insert
 edit-newline
 edit-backspace
 edit-delete
 edit-splice
 buffer-apply-edit
 buffer-apply-edit-trusted
 buffer-edit-desc-inverse
 buffer-put-property
 buffer-get-property
 buffer-remove-property
 buffer-put-properties-many
 buffer-put-restrict
 buffer-read-only-at?
 buffer-restrict-runs
 buffer-make-marker
 buffer-remove-marker
 buffer-marker-pos
 buffer-make-overlay
 buffer-remove-overlay
 edit-desc-after-position)

;;; ---------- 结构 ----------

(struct buffer
  (content      ; content.rkt
   gap          ; point.rkt       物理编辑位置（content.gap 的镜像，方便断言）
   markers      ; marker-table
   properties   ; properties
   overlays     ; overlay-table
   tick         ; nat             任何改动 +1（编辑 / 属性 / marker / patch）
   modified?)   ; boolean         用户编辑过？写标注不算
  #:transparent)

;;; ---------- 构造 ----------

(define (buffer-open s)
  (define c (content-of-string s))
  (buffer c
          (point (content-gap-line c) (content-gap-col c))
          (make-marker-table)
          (make-properties (content-line-count c))
          (make-overlay-table)
          0 #f))

;;; ---------- 投影 ----------

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines  b) (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))

;;; ---------- read-only 守卫 ----------
;;; read-only 是**约束槽**（restrict）里的语义，不是表现层属性。
;;; 规则：零宽插入 → 插入点严格在 read-only 区间内部则拒绝；
;;;       非零宽删除 → 删除区间 [s..e) 与任何 read-only 重叠则拒绝。
;;;
;;; 程序要编辑 read-only 内容时走**显式入口** buffer-splice-trusted——
;;; 不给守卫留任何隐式/全局开关（见 ARCHITECTURE §8.4）。

;; 该位置的约束是否含 read-only
(define (buffer-read-only-at? b line col)
  (restrict-read-only? (properties-restrict-at (buffer-properties b) line col)))

;; 一行内所有**约束槽**段： (listof (list start end restrict))，按 start 升序，
;; 恰好覆盖 [0, 行宽)，相邻段的 restrict 必不同。
;; 用途：**枚举**只读区间——`buffer-read-only-at?` 只能逐点问，这个是 O(段数)。
;; 行宽由文本给出，消费者不必自己算（presentation 侧的段分解见 properties-runs）。
(define (buffer-restrict-runs b line)
  (properties-restrict-runs (buffer-properties b) line
                            (string-length (buffer-line-ref b line))))

;; [s..e) 半开区间内是否有 read-only 字符
(define (range-read-only? b s-line s-col e-line e-col)
  (cond
    [(= s-line e-line)
     (for/or ([c (in-range s-col e-col)])
       (buffer-read-only-at? b s-line c))]
    [else
     (or (for/or ([c (in-range s-col (string-length (buffer-line-ref b s-line)))])
           (buffer-read-only-at? b s-line c))
         (for/or ([l (in-range (add1 s-line) e-line)])
           (for/or ([c (in-range (string-length (buffer-line-ref b l)))])
             (buffer-read-only-at? b l c)))
         (for/or ([c (in-range e-col)])
           (buffer-read-only-at? b e-line c)))]))

(define (edit-read-only? b desc)
  (define s-line (edit-desc-s-line desc))
  (define s-col (edit-desc-s-col desc))
  (define e-line (edit-desc-e-line desc))
  (define e-col (edit-desc-e-col desc))
  (if (and (= s-line e-line) (= s-col e-col))
      (buffer-read-only-at? b s-line s-col)
      (range-read-only? b s-line s-col e-line e-col)))

;;; ---------- 编辑核心 ----------

;; 在显式位置 (line, col) 执行一个 gap 编辑原语，返回 (values new-buffer desc)。
;; guard? = #f 时跳过 read-only 守卫（只有 buffer-splice-trusted 这么用）。
;; 无操作或触碰 read-only 时 desc = #f，原 buffer 原样返回。
(define (buffer-edit-at b line col edit-fn [guard? #t])
  (define c1 (content-gap-goto (buffer-content b) line col))
  (define-values (c2 desc) (edit-fn c1))
  (cond
    [(not desc) (values b #f)]
    [(and guard? (edit-read-only? b desc)) (values b #f)]   ; 触碰 read-only → 拒绝
    [else
     (define ng (point (content-gap-line c2) (content-gap-col c2)))
     ;; overlay-table-apply-edit 内部先调 marker-table-apply-edit，再 prune evaporate
     (define-values (ot* mt*)
       (overlay-table-apply-edit (buffer-overlays b) (buffer-markers b) desc))
     (values
      (buffer c2 ng
              mt*
              (properties-apply-edit (buffer-properties b) desc)
              ot*
              (add1 (buffer-tick b))
              #t)
      desc)]))

;; 统一 splice：删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）。
(define (buffer-splice b s-line s-col e-line e-col new-text)
  (buffer-edit-at b s-line s-col
                  (lambda (c) (content-splice c s-line s-col e-line e-col new-text))))

;; 与 buffer-splice 同形，但**跳过 read-only 守卫**：程序编辑 read-only 内容走这条。
;; 这是唯一的绕行入口（无全局开关）——见 ARCHITECTURE §8.4。
(define (buffer-splice-trusted b s-line s-col e-line e-col new-text)
  (buffer-edit-at b s-line s-col
                  (lambda (c) (content-splice c s-line s-col e-line e-col new-text))
                  #f))

(define (buffer-insert-char b line col ch)
  (buffer-edit-at b line col (lambda (c) (content-insert-char c ch))))

;; 插入一段文本（可含 \n）：一次 splice 完成。
(define (buffer-insert-string b line col s)
  (buffer-edit-at b line col (lambda (c) (content-insert-string c s))))

(define (buffer-newline b line col)
  (buffer-edit-at b line col content-newline))

(define (buffer-backspace b line col)
  (buffer-edit-at b line col content-backspace))

(define (buffer-delete b line col)
  (buffer-edit-at b line col content-delete))

;;; ---------- 编辑动作的规范函数（ARCHITECTURE §8.6）----------
;;; 把常用编辑变成**可传的值**，消费者不必再写 buffer 级 λ：
;;;     (on-edit a (edit-insert s))   而不是   (on-edit a (lambda (b l c) (buffer-insert-string b l c s)))
;;; 与 `edit-desc` 同族：一个**描述**一次编辑，一个**就是**那次编辑。
;;; 不关扩展性：自定义 λ 依然合法（document-edit 收的仍是函数）。

(define (edit-char ch)    (lambda (b l c) (buffer-insert-char b l c ch)))
(define (edit-insert s)   (lambda (b l c) (buffer-insert-string b l c s)))
(define (edit-newline)    buffer-newline)     ; 形状本来就一致，就是它
(define (edit-backspace)  buffer-backspace)
(define (edit-delete)     buffer-delete)
;; 通用逃生门：显式坐标的替换（程序化编辑，如"把选区换成这段文本"）
(define (edit-splice s-line s-col e-line e-col new-text)
  (lambda (b _l _c) (buffer-splice b s-line s-col e-line e-col new-text)))

;; 应用单个 edit-desc（buffer-splice 的 desc 版），返回 (values buffer desc)（desc 即 d）。
;; 与 edit.rkt 的 buffer-apply-edit-batch 不同：不批量、不重排、不查重叠。撤销/重放的落点。
(define (buffer-apply-edit b d)
  (buffer-splice b
                 (edit-desc-s-line d) (edit-desc-s-col d)
                 (edit-desc-e-line d) (edit-desc-e-col d)
                 (edit-desc-new-text d)))

;; 应用单个 edit-desc 的 trusted 版（跳过 read-only 守卫）：撤销/重放的落点。
;; 记录在案的编辑在当时都过了守卫（被拒的 desc=#f 不会被记录），所以重放不该被
;; **事后**才加的约束挡住——否则撤销会静默失灵（见 ARCHITECTURE §8.5）。
(define (buffer-apply-edit-trusted b d)
  (buffer-splice-trusted b
                         (edit-desc-s-line d) (edit-desc-s-col d)
                         (edit-desc-e-line d) (edit-desc-e-col d)
                         (edit-desc-new-text d)))

;; [s..e) 的文本（行间换行按 "\n" 归一，与 content 的规范形一致）
(define (buffer-range-text b s-line s-col e-line e-col)
  (cond
    [(= s-line e-line)
     (substring (buffer-line-ref b s-line) s-col e-col)]
    [else
     (string-join
      (append (list (substring (buffer-line-ref b s-line)
                               s-col (string-length (buffer-line-ref b s-line))))
              (for/list ([l (in-range (add1 s-line) e-line)])
                (buffer-line-ref b l))
              (list (substring (buffer-line-ref b e-line) 0 e-col)))
      "\n")]))

;; 逆编辑（文档级）：从「编辑前的 buffer」取回 d 删掉的文本，再求逆。
;; edit-desc 不含旧文本，所以 b 必须是 d 生效前的那一刻（不可变快照，留引用即可）。
;; 撤销用法：编辑时 (buffer-edit-desc-inverse b d) 压栈，撤销时 (buffer-apply-edit b* inv)。
(define (buffer-edit-desc-inverse b d)
  (edit-desc-inverse d
                     (buffer-range-text b
                                        (edit-desc-s-line d) (edit-desc-s-col d)
                                        (edit-desc-e-line d) (edit-desc-e-col d))))

;;; ---------- 一次编辑的完整材料 ----------
;;; desc 与 inv 都是 edit-desc（同类型、字段相邻），散着传时写反不报错、只静默写坏
;;; 历史——所以打成 struct：以数据表达「这三样属于同一次编辑」。
;;; pre-point 只由**持有光标**的层（window / document）填——buffer 层没有光标，
;;; 也就不产出 edit-change。
(struct edit-change (desc inv pre-point) #:transparent)
;; desc      : edit-desc  这次编辑（操作前坐标）—— 重放用它
;; inv       : edit-desc  逆（操作后坐标，由**编辑前**的 buffer 导出）—— 撤销用它
;; pre-point : point      编辑视图在编辑前的光标 —— 撤销后回到这里

;;; ---------- 输入夹紧与校验（ARCHITECTURE §8.5 R1/R2）----------
;;; 两类违约分开处理：
;;;   有唯一合法解释 → 夹紧（越界行列、超出行长的属性端点）
;;;   没有合法解释   → 报错（区间反向/为空、位置不在 buffer 内）

;; 把属性/约束的 (line start end) 夹到合法域：行号夹到行界内、端点夹到该行长度。
;; 空区间/反向由 properties 层报错（见 properties.rkt row-modify）。
(define (clamp-prop-range b line start end)
  (define n (buffer-line-count b))
  (define l (max 0 (min line (sub1 n))))
  (define len (string-length (buffer-line-ref b l)))
  (values l (max 0 (min start len)) (max 0 (min end len))))

;; marker/overlay 的位置必须能在 buffer 里解释：越界位置永远不会被编辑修正、
;; 由它构成的 overlay 永不显示（见 ARCHITECTURE §8.5 A5）。
(define (check-buffer-position who b pos)
  (define n (buffer-line-count b))
  (define l (point-line pos))
  (define c (point-col pos))
  (define len (and (exact-nonnegative-integer? l)
                   (< l n)
                   (string-length (buffer-line-ref b l))))
  (unless (and len (exact-nonnegative-integer? c) (<= c len))
    (error who "位置不在 buffer 内: (line col) = (~a ~a)；共 ~a 行~a" l c n
           (if len (format "，第 ~a 行 ~a 列" l len) ""))))

;;; ---------- 属性 ----------

(define (buffer-put-property b line start end prop val)
  (define-values (l s e) (clamp-prop-range b line start end))
  (struct-copy buffer b
    [properties (properties-put (buffer-properties b) l s e prop val)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

(define (buffer-get-property b line col prop)
  (properties-get (buffer-properties b) line col prop))

;; 只清掉 [start,end) 上某个 key。插件应只清「自己负责的 key」，避免互相清空。
(define (buffer-remove-property b line start end prop)
  (define-values (l s e) (clamp-prop-range b line start end))
  (struct-copy buffer b
    [properties (properties-remove (buffer-properties b) l s e prop)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;; 批量写属性，一次 tick：segs = (listof (list line start end prop val))
(define (buffer-put-properties-many b segs)
  (if (null? segs)
      b
      (let* ([segs* (for/list ([s (in-list segs)])
                      (define-values (l a z) (clamp-prop-range b (car s) (cadr s) (caddr s)))
                      (list* l a z (cdddr s)))]
             [properties* (properties-put-many (buffer-properties b) segs*)])
        (struct-copy buffer b
          [properties properties*]
          [tick (add1 (buffer-tick b))]
          [modified? #t]))))

;; 写约束槽（只动约束，不碰表现层）。传 (make-restrict) 即清除该区间的约束。
(define (buffer-put-restrict b line start end rs)
  (define-values (l s e) (clamp-prop-range b line start end))
  (struct-copy buffer b
    [properties (properties-put-restrict (buffer-properties b) l s e rs)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;;; ---------- marker ----------

(define (buffer-make-marker b pos [type 'before])
  (check-buffer-position 'buffer-make-marker b pos)
  (define-values (mt id) (marker-table-add (buffer-markers b) pos type))
  (values (struct-copy buffer b
            [markers mt]
            [tick (add1 (buffer-tick b))]
            [modified? #t])
          id))

(define (buffer-remove-marker b id)
  (struct-copy buffer b
    [markers (marker-table-remove (buffer-markers b) id)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

(define (buffer-marker-pos b id)
  (define m (marker-table-get (buffer-markers b) id))
  (and m (marker-pos m)))

;;; ---------- overlay ----------

(define (buffer-make-overlay b start-pos end-pos [presentation (hash)]
                             #:priority [priority 0]
                             #:evaporate? [evaporate? #f])
  (check-buffer-position 'buffer-make-overlay b start-pos)
  (check-buffer-position 'buffer-make-overlay b end-pos)
  (when (pos<? (point-line end-pos) (point-col end-pos)
               (point-line start-pos) (point-col start-pos))
    (error 'buffer-make-overlay "overlay 区间反向: (~a ~a)..(~a ~a)"
           (point-line start-pos) (point-col start-pos)
           (point-line end-pos) (point-col end-pos)))
  (define-values (b1 sid) (buffer-make-marker b start-pos 'before))
  (define-values (b2 eid) (buffer-make-marker b1 end-pos 'after))
  (define-values (ot oid)
    (overlay-table-add (buffer-overlays b2) sid eid presentation
                       #:priority priority #:evaporate? evaporate?))
  (values (struct-copy buffer b2
            [overlays ot]
            [tick (add1 (buffer-tick b2))]
            [modified? #t])
          oid))

(define (buffer-remove-overlay b oid)
  (struct-copy buffer b
    [overlays (overlay-table-remove (buffer-overlays b) oid)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))

  ;; 基本
  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines  b0) (list "hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-tick b0) 0)

  ;; insert（显式位置）：返回 (values buffer desc)
  (define-values (b1 d1) (buffer-insert-char b0 0 0 #\X))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? (buffer-tick b1) 1)
  (check-equal? d1 (edit-desc 0 0 0 0 "X"))
  (check-equal? (edit-desc-after-position d1) (point 0 1))

  ;; newline
  (define-values (b2 d2) (buffer-newline b0 0 0))
  (check-equal? (buffer->string b2) "\nhello\nworld")
  (check-equal? (buffer-line-count b2) 3)
  (check-equal? d2 (edit-desc 0 0 0 0 "\n"))
  (check-equal? (edit-desc-after-position d2) (point 1 0))

  ;; backspace 合并（第 2 行行首）
  (define-values (b3 d3) (buffer-backspace b0 1 0))
  (check-equal? (buffer->string b3) "helloworld")
  (check-equal? d3 (edit-desc 0 5 1 0 ""))
  (check-equal? (edit-desc-after-position d3) (point 0 5))

  ;; delete 合并（第 1 行行尾）
  (define-values (b4 d4) (buffer-delete b0 0 5))
  (check-equal? (buffer->string b4) "helloworld")
  (check-equal? d4 (edit-desc 0 5 1 0 ""))

  ;; 无操作边界：desc = #f，且原 buffer 原样返回
  (define-values (b-nop d-nop) (buffer-backspace b0 0 0))
  (check-eq? b-nop b0)
  (check-false d-nop)

  ;; 多行插入（paste）
  (define-values (bp dp) (buffer-insert-string b0 0 0 "X\nY"))
  (check-equal? (buffer->string bp) "X\nYhello\nworld")
  (check-equal? dp (edit-desc 0 0 0 0 "X\nY"))
  (check-equal? (edit-desc-after-position dp) (point 1 1))
  ;; 尾部换行保留空行
  (define-values (bp2 _1) (buffer-insert-string b0 0 0 "A\n"))
  (check-equal? (buffer->string bp2) "A\nhello\nworld")

  ;; splice：跨行删除 + 多行插入
  (define bsp (buffer-open "abcd\nefgh\nijkl"))
  (define-values (bsp1 dsp) (buffer-splice bsp 0 1 2 1 "XY\nZ"))
  (check-equal? (buffer->string bsp1) "aXY\nZjkl")
  (check-equal? dsp (edit-desc 0 1 2 1 "XY\nZ"))

  ;; 属性
  (define b7 (buffer-put-property b0 0 1 4 'face 'bold))
  (check-equal? (buffer-get-property b7 0 0 'face) #f)
  (check-equal? (buffer-get-property b7 0 2 'face) 'bold)
  (check-equal? (buffer-get-property b7 0 4 'face) #f)

  ;; 属性随编辑移动：插在 bold 区间内，新区间扩张
  (define-values (b8 _2) (buffer-insert-char b7 0 2 #\Z))
  (check-equal? (buffer->string b8) "heZllo\nworld")
  (check-equal? (buffer-get-property b8 0 2 'face) 'bold)  ; 新字符继承

  ;; marker
  (define-values (b9 mid) (buffer-make-marker b0 (point 0 3)))
  (check-equal? (buffer-marker-pos b9 mid) (point 0 3))
  ;; 在 marker 前插入 → marker 右移
  (define-values (b10 _3) (buffer-insert-char b9 0 0 #\a))
  (check-equal? (buffer-marker-pos b10 mid) (point 0 4))
  ;; 删除 marker 前字符 → marker 左移
  (define-values (b11 _4) (buffer-delete b10 0 0))
  (check-equal? (buffer-marker-pos b11 mid) (point 0 3))

  ;; overlay
  (define-values (b12 oid) (buffer-make-overlay b0 (point 0 1) (point 0 4)
                                                 (hash 'face 'region)))
  (define-values (b13 _5) (buffer-insert-char b12 0 0 #\a))
  (define runs (overlay-table-runs (buffer-overlays b13) (buffer-markers b13) 0 10))
  (check-equal? (length runs) 1)
  (check-equal? (car  (car runs)) 2)   ; start 右移到 2
  (check-equal? (cadr (car runs)) 5)   ; end 右移到 5

  ;; overlay evaporate
  (define-values (b14 oid2) (buffer-make-overlay b0 (point 0 1) (point 0 3)
                                                  (hash 'face 'region) #:evaporate? #t))
  ;; 连续删 3 次，overlay 覆盖的字符全删光
  (define-values (b15 _6) (buffer-delete b14 0 1))
  (define-values (b16 _7) (buffer-delete b15 0 1))
  (define-values (b17 _8) (buffer-delete b16 0 1))
  (check-equal? (overlay-table-count (buffer-overlays b17)) 0)

  ;; tick 单调递增
  (check-equal? (buffer-tick b17)
                (+ (buffer-tick b14) 3))   ; 3 次 delete（overlay 建立的 +3 已在 b14 里）

  ;; read-only 守卫：约束槽里标了 read-only 的区间不可编辑
  (define rb (buffer-put-restrict b0 0 1 4 (restrict #t)))   ; "ell"（col 1~3）不可编辑
  ;; 区间内部插入 → 拒绝（原 buffer 原样返回）
  (define-values (rb1 rd1) (buffer-insert-char rb 0 2 #\X))
  (check-eq? rb1 rb)
  (check-false rd1)
  ;; 区间末尾边界（col 4）插入 → 允许，且新字符不继承 read-only（非粘性）
  (define-values (rb2 rd2) (buffer-insert-char rb 0 4 #\X))
  (check-equal? (buffer->string rb2) "hellXo\nworld")
  (check-false (buffer-read-only-at? rb2 0 4))
  (check-true  (buffer-read-only-at? rb2 0 2))   ; 原区间仍在
  ;; 约束与表现互不干扰
  (define rb-f (buffer-put-property rb 0 1 4 'face 'prompt))
  (check-equal? (buffer-get-property rb-f 0 2 'face) 'prompt)
  (check-true (buffer-read-only-at? rb-f 0 2))

  ;; 枚举只读区间：buffer-restrict-runs（O(段数) 拿到区间；逐点问是 O(列数)）
  (check-equal? (buffer-restrict-runs b0 0) (list (list 0 5 (make-restrict))))   ; 无约束
  (check-equal? (buffer-restrict-runs rb 0)                                     ; 行 0：[1,4) 只读
                (list (list 0 1 (make-restrict)) (list 1 4 (restrict #t)) (list 4 5 (make-restrict))))
  ;; presentation 的段不影响约束的切分（rb-f 行 0 有 face 段，约束段仍是三段）
  (check-equal? (buffer-restrict-runs rb-f 0) (buffer-restrict-runs rb 0))
  ;; 编辑后区间跟着走：行 0 头部插一个字符 → [1,4) 变 [2,5)
  (define-values (rrz _rrzd) (buffer-insert-char rb 0 0 #\X))
  (check-equal? (buffer-restrict-runs rrz 0)
                (list (list 0 2 (make-restrict)) (list 2 5 (restrict #t)) (list 5 6 (make-restrict))))
  ;; 一行两段只读（中间可写）
  (define rry (buffer-put-restrict (buffer-put-restrict b0 0 0 2 (restrict #t)) 1 0 3 (restrict #t)))
  (check-equal? (buffer-restrict-runs rry 0)
                (list (list 0 2 (restrict #t)) (list 2 5 (make-restrict))))
  (check-equal? (buffer-restrict-runs rry 1)
                (list (list 0 3 (restrict #t)) (list 3 5 (make-restrict))))
  ;; 清除约束（传空约束）
  (check-false (buffer-read-only-at? (buffer-put-restrict rb 0 1 4 (make-restrict)) 0 2))
  ;; 删除跨进 read-only → 拒绝
  (define-values (rb3 rd3) (buffer-backspace rb 0 4))   ; 删 [3,4) ∈ [1,4)
  (check-eq? rb3 rb)
  (check-false rd3)
  ;; 删除 read-only 之外 → 允许
  (define-values (rb4 rd4) (buffer-backspace rb 0 5))   ; 删 [4,5)（"o"，不在 read-only）
  (check-equal? (buffer->string rb4) "hell\nworld")

  ;; buffer-splice-trusted：程序编辑 read-only 内容的**唯一显式入口**
  (define-values (rb5 rd5) (buffer-splice-trusted rb 0 2 0 2 "X"))
  (check-equal? (buffer->string rb5) "heXllo\nworld")
  (check-equal? rd5 (edit-desc 0 2 0 2 "X"))
  ;; 对照：带守卫的 buffer-splice 在同一位置被拒
  (check-eq? (let-values ([(b* _d) (buffer-splice rb 0 2 0 2 "X")]) b*) rb)

  ;; ---- undo 原语：edit-desc 的逆（需编辑前的 buffer 取回被删文本）----
  ;; 便于测试：应用 desc 只看 buffer（buffer-apply-edit 返回 (values buffer desc)）
  (define (apply1 b d) (let-values ([(b* _) (buffer-apply-edit b d)]) b*))
  (define (apply1-trusted b d)
    (let-values ([(b* _) (buffer-apply-edit-trusted b d)]) b*))
  (define u0 (buffer-open "abcd\nefgh"))
  ;; buffer-apply-edit 与产生该 desc 的编辑等价
  (define-values (u1 du1) (buffer-insert-string u0 0 1 "XY\nZ"))
  (check-equal? (buffer->string u1) "aXY\nZbcd\nefgh")     ; 纯插入，旧文本整段保留
  (check-equal? (buffer->string (apply1 u0 du1)) (buffer->string u1))
  ;; 纯插入（跨行）的逆 = 删掉插入的文本
  (define inv1 (buffer-edit-desc-inverse u0 du1))
  (check-equal? (buffer->string (apply1 u1 inv1)) "abcd\nefgh")
  ;; 逆的逆：inv1 相对 u1，其逆相对 u0 —— 应用到 u0 得回 u1（纯插入时 == 原 desc）
  (check-equal? (buffer->string (apply1 u0 (buffer-edit-desc-inverse u1 inv1)))
                (buffer->string u1))
  ;; 纯删除（跨行）的逆 = 在起点插回被删文本
  (define-values (u2 du2) (buffer-splice u0 0 1 1 2 ""))
  (check-equal? (buffer->string u2) "agh")
  (check-equal? (buffer->string (apply1 u2 (buffer-edit-desc-inverse u0 du2)))
                "abcd\nefgh")
  ;; 单字符删除的逆
  (define u3 (buffer-open "hello"))
  (define-values (u4 du4) (buffer-delete u3 0 0))
  (check-equal? (buffer->string (apply1 u4 (buffer-edit-desc-inverse u3 du4)))
                "hello")
  ;; 替换（删+插）的逆
  (define-values (u5 du5) (buffer-splice u0 0 0 0 2 "Z"))
  (check-equal? (buffer->string u5) "Zcd\nefgh")
  (check-equal? (buffer->string (apply1 u5 (buffer-edit-desc-inverse u0 du5)))
                "abcd\nefgh")

  ;; ---- buffer-apply-edit-trusted：撤销/重放走 trusted ----
  ;; 对照：编辑之后才加的 read-only —— 守卫版拒绝（撤销会静默失灵），trusted 版通过
  (define v0 (buffer-open "hello"))
  (define-values (v1 vd) (buffer-insert-string v0 0 1 "X"))   ; "hXello"
  (define vinv (buffer-edit-desc-inverse v0 vd))
  (define vr (buffer-put-restrict v1 0 1 2 (restrict #t)))     ; 事后把 "X" 标成 read-only
  (check-eq? (apply1 vr vinv) vr)                              ; 守卫版：原样返回（desc=#f）
  (check-equal? (buffer->string (apply1 vr vinv)) "hXello")
  (check-equal? (buffer->string (apply1-trusted vr vinv)) "hello")   ; trusted 版：撤销生效
  ;; 被恢复的文本不带它被删时的约束/表现（区间随删除塌缩）
  (check-false (buffer-read-only-at? (apply1-trusted vr vinv) 0 1))
  ;; 无约束时两版等价
  (check-equal? (buffer->string (apply1-trusted v1 vinv))
                (buffer->string (apply1 v1 vinv)))

  ;; ---- A 组回归：曾经的静默行为现在报错 / 夹紧（ARCHITECTURE §8.5）----

  ;; A1：区间反向 → 报错（原来会静默复制文本："abcdef" → "abcbcdef"）
  (check-exn exn:fail?
             (lambda () (buffer-splice (buffer-open "abcdef") 0 3 0 1 "")))
  (check-exn exn:fail?
             (lambda () (buffer-splice (buffer-open "abc\ndef") 1 0 0 1 "")))
  ;; A1：越界端点仍**夹紧**（有唯一合法解释），且 desc 报夹紧后的坐标
  (define-values (oob od) (buffer-splice (buffer-open "abc") 0 1 0 99 ""))
  (check-equal? (buffer->string oob) "a")            ; 删 [1,3)
  (check-equal? od (edit-desc 0 1 0 3 ""))
  (check-equal? (buffer->string
                 (let-values ([(b* _) (buffer-splice (buffer-open "abc") 0 99 0 99 "X")]) b*))
                "abcX")

  ;; A2：属性/约束区间为空或反向 → 报错（原来静默不写，写只读区"以为锁住了没锁"）
  (check-exn exn:fail?
             (lambda () (buffer-put-restrict (buffer-open "abcdef") 0 2 2 (restrict #t))))
  (check-exn exn:fail?
             (lambda () (buffer-put-property (buffer-open "abcdef") 0 4 2 'face 'x)))
  ;; A2：端点超出行长 → 夹到行长（不是报错）
  (define clamped (buffer-put-property (buffer-open "abc") 0 1 99 'face 'x))
  (check-equal? (buffer-get-property clamped 0 2 'face) 'x)
  (check-equal? (buffer-get-property (buffer-put-property (buffer-open "abc") 0 1 99 'face 'x) 0 0 'face) #f)

  ;; A5：marker/overlay 位置必须在 buffer 内；overlay 不能反向
  (check-exn exn:fail? (lambda () (buffer-make-marker (buffer-open "abc") (point 9 0))))
  (check-exn exn:fail? (lambda () (buffer-make-marker (buffer-open "abc") (point 0 9))))
  (check-exn exn:fail?
             (lambda () (buffer-make-overlay (buffer-open "abc\ndef") (point 1 0) (point 0 1))))
  ;; A5：边界合法（行尾 = 行长）
  (check-true (let-values ([(b* _) (buffer-make-marker (buffer-open "abc") (point 0 3))]) (buffer? b*)))

  ;; ---- §8.6：编辑动作的规范函数 ----
  (define (run-op op b l c) (let-values ([(b* d) (op b l c)]) (values b* d)))
  (define (op-b op b l c) (let-values ([(b* _) (op b l c)]) b*))
  (define edop-b (buffer-open "abc"))
  (check-equal? (buffer->string (op-b (edit-insert "XY") edop-b 0 1)) "aXYbc")
  (check-equal? (buffer->string (op-b (edit-newline) edop-b 0 1)) "a\nbc")
  (check-equal? (buffer->string (op-b (edit-backspace) edop-b 0 2)) "ac")
  (check-equal? (buffer->string (op-b (edit-delete) edop-b 0 1)) "ac")
  (check-equal? (buffer->string (op-b (edit-splice 0 0 0 1 "Z") edop-b 0 0)) "Zbc")
  ;; 与手写 λ 逐字等价（含 desc）
  (check-equal? (let-values ([(b* d) (run-op (edit-insert "XY") edop-b 0 1)]) (list (buffer->string b*) d))
                (let-values ([(b* d) ((lambda (bb l c) (buffer-insert-string bb l c "XY")) edop-b 0 1)])
                  (list (buffer->string b*) d)))
  ;; 那几个"直接就是原语"的（同一过程对象），插入那个是构造器（每次新闭包）
  (check-eq? (edit-newline) buffer-newline)
  (check-eq? (edit-backspace) buffer-backspace)
  (check-false (eq? (edit-insert "x") (edit-insert "x")))

  ;; edit-char ≡ (edit-insert (string ch))，含 desc
  (check-equal? (buffer->string (op-b (edit-char #\X) edop-b 0 1)) "aXbc")
  (check-equal? (let-values ([(b* d) (run-op (edit-char #\X) edop-b 0 1)]) (list (buffer->string b*) d))
                (let-values ([(b* d) (run-op (edit-insert "X") edop-b 0 1)]) (list (buffer->string b*) d)))

  ;; ---- edit-change：一次编辑的完整材料（纯数据，由**持有光标**的层组装）----
  (define ec0 (buffer-open "abcdef"))
  (define-values (ec1 ec-d) (buffer-delete ec0 0 2))      ; 删 'c'（[2,3)）
  (define ec-ch (edit-change ec-d (buffer-edit-desc-inverse ec0 ec-d) (point 0 2)))
  (check-true (edit-change? ec-ch))
  (check-equal? (edit-change-desc ec-ch) (edit-desc 0 2 0 3 ""))
  (check-equal? (edit-change-inv ec-ch) (edit-desc 0 2 0 2 "c"))   ; 逆 = 在起点插回 'c'
  (check-equal? (edit-change-pre-point ec-ch) (point 0 2))
  ;; 撤销 = 施加逆，回到原状
  (check-equal? (buffer->string (apply1 ec1 (edit-change-inv ec-ch))) "abcdef")

  (displayln "buffer.rkt: all tests passed"))
