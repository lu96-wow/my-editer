#lang racket

(require "point.rkt" "content.rkt" "marker.rkt"
         "properties.rkt" "overlay.rkt" rackunit)

;;; buffer.rkt —— 文档：文本 + 元数据 + 脏范围（无光标）
;;;
;;; 组合根。所有编辑原语在这里装配：
;;;   1. sync gap 到给定位置 (line, col)
;;;   2. content-edit → (content', desc)
;;;   3. overlay-table-apply-edit ot mt desc → (ot', mt')
;;;      （内部先调 marker-table-apply-edit，再判 evaporate）
;;;   4. properties-apply-edit props desc → props'
;;;   5. 更新 tick / dirty
;;;
;;; 光标（point）不属于文档，属于 window：一个 buffer 可被多个 window 绑定，
;;; 每个 window 有自己的 point。所以本文件的编辑原语都要求显式位置。

(provide
 (struct-out buffer)
 (struct-out dirty-desc)
 (struct-out edit-desc)
 buffer-open
 buffer->string
 buffer->lines
 buffer-line-count
 buffer-line-ref
 buffer-splice
 buffer-insert-char
 buffer-insert-string
 buffer-newline
 buffer-backspace
 buffer-delete
 buffer-put-property
 buffer-get-property
 buffer-remove-property
 buffer-put-properties-many
 buffer-make-marker
 buffer-delete-marker
 buffer-marker-pos
 buffer-make-overlay
 buffer-delete-overlay
 buffer-mark-dirty
 buffer-mark-dirty-all
 buffer-clean
 inhibit-read-only
 with-read-only-inhibited
 edit-desc-after-position)

;;; ---------- 结构 ----------

(struct dirty-desc (first-line last-line old-count new-count) #:transparent)

(struct buffer
  (content      ; content.rkt
   gap          ; point.rkt       物理编辑位置（content.gap 的镜像，方便断言）
   markers      ; marker-table
   properties   ; properties
   overlays     ; overlay-table
   tick         ; nat
   dirty        ; (or/c #f dirty-desc)
   modified?)   ; boolean
  #:transparent)

;;; ---------- 构造 ----------

(define (buffer-open s)
  (define c (content-of-string s))
  (buffer c
          (point (content-gap-line c) (content-gap-col c))
          (make-marker-table)
          (make-properties (content-line-count c))
          (make-overlay-table)
          0 #f #f))

;;; ---------- 投影 ----------

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines  b) (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))

;;; ---------- dirty 计算 ----------
;;; dirty 用「新 buffer 坐标系」。渲染时直接用它索引新行表。

(define (dirty-of desc old-count new-count)
  (define s-line (edit-desc-s-line desc))
  (define k (length (string->lines (edit-desc-new-text desc))))
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

;;; ---------- read-only 守卫 ----------
;;; 'read-only 文本属性：标了它的区间用户不可编辑。
;;; 规则：零宽插入 → 插入点严格在 read-only 区间内部则拒绝；
;;;       非零宽删除 → 删除区间 [s..e) 与任何 read-only 重叠则拒绝。
;;;
;;; 程序要编辑 read-only 内容时，用 with-read-only-inhibited 暂时绕过守卫。

(define inhibit-read-only (make-parameter #f))

;; 在 body 内暂时抑制 read-only 守卫（允许编辑 read-only 内容），退出后自动恢复。
(define-syntax-rule (with-read-only-inhibited body ...)
  (parameterize ([inhibit-read-only #t])
    body ...))

(define (read-only-at? b line col)
  (buffer-get-property b line col 'read-only))

;; [s..e) 半开区间内是否有 read-only 字符
(define (range-read-only? b s-line s-col e-line e-col)
  (cond
    [(= s-line e-line)
     (for/or ([c (in-range s-col e-col)])
       (read-only-at? b s-line c))]
    [else
     (or (for/or ([c (in-range s-col (string-length (buffer-line-ref b s-line)))])
           (read-only-at? b s-line c))
         (for/or ([l (in-range (add1 s-line) e-line)])
           (for/or ([c (in-range (string-length (buffer-line-ref b l)))])
             (read-only-at? b l c)))
         (for/or ([c (in-range e-col)])
           (read-only-at? b e-line c)))]))

(define (edit-read-only? b desc)
  (define s-line (edit-desc-s-line desc))
  (define s-col (edit-desc-s-col desc))
  (define e-line (edit-desc-e-line desc))
  (define e-col (edit-desc-e-col desc))
  (if (and (= s-line e-line) (= s-col e-col))
      (read-only-at? b s-line s-col)
      (range-read-only? b s-line s-col e-line e-col)))

;;; ---------- 编辑核心 ----------

;; 在显式位置 (line, col) 执行一个 gap 编辑原语，返回 (values new-buffer desc)。
;; 无操作或触碰 read-only 时 desc = #f，原 buffer 原样返回。
(define (buffer-edit-at b line col edit-fn)
  (define c1 (content-gap-goto (buffer-content b) line col))
  (define-values (c2 desc) (edit-fn c1))
  (cond
    [(not desc) (values b #f)]
    [(and (not (inhibit-read-only)) (edit-read-only? b desc)) (values b #f)]   ; 触碰 read-only → 拒绝（除非程序绕过）
    [else
     (define old-count (content-line-count c1))
     (define new-count (content-line-count c2))
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
              (merge-dirty (buffer-dirty b) (dirty-of desc old-count new-count))
              #t)
      desc)]))

;; 统一 splice：删除 [s-line,s-col)..[e-line,e-col)，插入 new-text（可含 \n）。
(define (buffer-splice b s-line s-col e-line e-col new-text)
  (buffer-edit-at b s-line s-col
                  (lambda (c) (content-splice c s-line s-col e-line e-col new-text))))

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

;;; ---------- 属性 ----------

(define (buffer-put-property b line start end prop val)
  (struct-copy buffer b
    [properties (properties-put (buffer-properties b) line start end prop val)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

(define (buffer-get-property b line col prop)
  (properties-get (buffer-properties b) line col prop))

;; 只清掉 [start,end) 上某个 key。插件应只清「自己负责的 key」，避免互相清空。
(define (buffer-remove-property b line start end prop)
  (struct-copy buffer b
    [properties (properties-remove (buffer-properties b) line start end prop)]
    [tick (add1 (buffer-tick b))]
    [modified? #t]))

;; 批量写属性，一次 tick：segs = (listof (list line start end prop val))
(define (buffer-put-properties-many b segs)
  (if (null? segs)
      b
      (let ([properties* (properties-put-many (buffer-properties b) segs)])
        (struct-copy buffer b
          [properties properties*]
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
  (check-equal? (buffer-tick b0) 0)
  (check-false (buffer-dirty b0))

  ;; insert（显式位置）：返回 (values buffer desc)
  (define-values (b1 d1) (buffer-insert-char b0 0 0 #\X))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? (buffer-tick b1) 1)
  (check-equal? (buffer-dirty b1) (dirty-desc 0 0 2 2))
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
                                                  (hash 'face 'region 'evaporate #t)))
  ;; 连续删 3 次，overlay 覆盖的字符全删光
  (define-values (b15 _6) (buffer-delete b14 0 1))
  (define-values (b16 _7) (buffer-delete b15 0 1))
  (define-values (b17 _8) (buffer-delete b16 0 1))
  (check-equal? (overlay-table-count (buffer-overlays b17)) 0)

  ;; clean
  (check-false (buffer-dirty (buffer-clean b1)))
  (check-equal? (buffer-tick (buffer-clean b1)) 1)  ; tick 不变

  ;; tick 单调递增
  (check-equal? (buffer-tick b17)
                (+ (buffer-tick b14) 3))   ; 3 次 delete（overlay 建立的 +3 已在 b14 里）

  ;; read-only 守卫：标了 'read-only 的区间不可编辑
  (define rb (buffer-put-property b0 0 1 4 'read-only #t))   ; "ell"（col 1~3）不可编辑
  ;; 区间内部插入 → 拒绝（原 buffer 原样返回）
  (define-values (rb1 rd1) (buffer-insert-char rb 0 2 #\X))
  (check-eq? rb1 rb)
  (check-false rd1)
  ;; 区间末尾边界（col 4）插入 → 允许，且新字符不继承 read-only（非粘性）
  (define-values (rb2 rd2) (buffer-insert-char rb 0 4 #\X))
  (check-equal? (buffer->string rb2) "hellXo\nworld")
  (check-equal? (buffer-get-property rb2 0 4 'read-only) #f)
  (check-equal? (buffer-get-property rb2 0 2 'read-only) #t)   ; 原区间仍在
  ;; 删除跨进 read-only → 拒绝
  (define-values (rb3 rd3) (buffer-backspace rb 0 4))   ; 删 [3,4) ∈ [1,4)
  (check-eq? rb3 rb)
  (check-false rd3)
  ;; 删除 read-only 之外 → 允许
  (define-values (rb4 rd4) (buffer-backspace rb 0 5))   ; 删 [4,5)（"o"，不在 read-only）
  (check-equal? (buffer->string rb4) "hell\nworld")

  ;; with-read-only-inhibited：程序编辑 read-only 内容
  (define-values (rb5 rd5)
    (with-read-only-inhibited
      (buffer-insert-char rb 0 2 #\X)))          ; 在 read-only 区间内插入
  (check-equal? (buffer->string rb5) "heXllo\nworld")
  (check-equal? rd5 (edit-desc 0 2 0 2 "X"))

  (displayln "buffer.rkt: all tests passed"))
