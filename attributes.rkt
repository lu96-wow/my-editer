#lang racket

;;; attributes.rkt —— 属性的修改：写 / 读 / 清 / 约束槽 / 编辑时自动跟随 / patch
;;;
;;; 两个要点：
;;;   1. 属性按**位置**存在按行切分的 span 里，**编辑时自动跟着文本移动**
;;;      （`buffer-edit-at` 这个唯一漏斗里就调 properties-apply-edit）——写一次，之后不用管。
;;;   2. **表现层（face）与约束（read-only）是两个槽**：前者是样式，后者是编辑器语义。
;;;
;;; 必要 API：
;;;   写    buffer-put-property        buffer-put-properties-many    buffer-remove-property
;;;   读    buffer-get-property
;;;   约束  buffer-put-restrict        make-restrict                buffer-read-only-at?
;;;   补丁  patch     buffer-apply-patches     buffer-content-same?
;;;   文本  buffer-open     buffer->string     buffer-insert-char     buffer-splice

(require "core/api.rkt" rackunit)

;; 读一个 key 的别名（例子里到处要用）
(define (face b line col) (buffer-get-property b line col 'face))

;;; ---------- 1. 写：一个 key 的一段 ----------

(define b0 (buffer-open "hello\nworld"))
(define b1 (buffer-put-property b0 0 0 5 'face 'bold))      ; 行 0 的 [0,5) 全给 bold

;; 同 key 再写一段 → 按位置切开： [0,2) red ＋ [2,5) bold
(define b2 (buffer-put-property b1 0 0 2 'face 'red))

;; 一次写多段（一次重建，胜过多轮单写）
;; segs = (listof (list line start end prop val))
(define b3 (buffer-put-properties-many b2
            (list (list 0 3 4 'face 'underline)     ; 行 0 的 [3,4)
                  (list 1 0 5 'face 'italic))))    ; 行 1 的 [0,5)

;;; ---------- 2. 清：只清掉某一段上的这个 key ----------

(define b3-none (buffer-remove-property b3 0 0 5 'face))

;;; ---------- 3. 编辑时自动跟随（属性不是插件要维护的东西）----------

;; 行 0 列 0 插一个字符 → 该行属性整体右移一位，新字符没有 face
;; （编辑原语返回 (values 新 buffer 事实-or-#f)，这里不要事实，第二值丢掉）
(define-values (b4 _d4) (buffer-insert-char b3 0 0 #\X))

;; 删掉行 0 末尾的换行 → 两行合并，行 1 的属性跟着并到行 0
(define-values (b5 _d5) (buffer-splice b4 0 6 1 0 ""))

;;; ---------- 4. 约束槽：read-only（写进去以后，编辑漏斗会拒绝）----------

(define c0 (buffer-put-restrict b0 0 1 4 (restrict #t)))        ; 行 0 的 [1,4) 只读
(define-values (c1 c1-desc) (buffer-insert-char c0 0 1 #\X))    ; 插入点在只读区**内部** → 拒绝
(define-values (c2 c2-desc) (buffer-insert-char c0 0 4 #\X))    ; 紧贴区间右边界（已在区间外）→ 允许
(define c3 (buffer-put-restrict c0 0 1 4 (make-restrict)))      ; 传空约束 = 清除
(define-values (c4 c4-desc) (buffer-insert-char c3 0 1 #\X))    ; 清除后同一点就能编辑

;;; ---------- 5. patch：插件输出 = delta（按 key 清旧写新）----------

(define p0 (buffer-apply-patches b0 (list (patch 'diag 0 0 (list (list 0 0 5 "err"))))))
(define p1 (buffer-apply-patches p0 (list (patch 'diag 0 0 '()))))                ; 空 patch = 清旧
(define p2 (buffer-apply-patches b0 (list (patch 'face 0 0 (list (list 0 0 5 'bold)))
                                           (patch 'diag 0 0 (list (list 0 0 5 "err"))))))

;;; ---------- 走一遍 ----------

(module+ main
  (displayln (format "① bold[0,5)        (0,1)=~a  (0,3)=~a" (face b1 0 1) (face b1 0 3)))
  (displayln (format "   再写 red[0,2)    (0,1)=~a  (0,3)=~a   ← 同 key 按位置切开"
                     (face b2 0 1) (face b2 0 3)))
  (displayln (format "   多段一次写       (0,2)=~a  (0,3)=~a  (1,2)=~a"
                     (face b3 0 2) (face b3 0 3) (face b3 1 2)))
  (displayln (format "   清掉行 0 的 face (0,2)=~a                ← 只清自己那个 key"
                     (face b3-none 0 2)))
  (displayln (format "② 行 0 插字符      (0,0)=~a  (0,1)=~a  (0,5)=~a  ← 属性右移，新字符无 face"
                     (face b4 0 0) (face b4 0 1) (face b4 0 5)))
  (displayln (format "③ 合并两行        ~s" (buffer->string b5)))
  (displayln (format "   行 1 的 italic 并过来：(0,7)=~a" (face b5 0 7)))
  (displayln (format "④ 只读 [1,4)      (0,2) 只读？~a" (buffer-read-only-at? c0 0 2)))
  (displayln (format "   插在 (0,1)      desc=~a 文本=~s   ← 被守卫拒绝"
                     c1-desc (buffer->string c1)))
  (displayln (format "   插在 (0,4)      desc非#f？~a 文本=~s ← 区间外，允许"
                     (and c2-desc #t) (buffer->string c2)))
  (displayln (format "   清除约束后 (0,1) desc非#f？~a 文本=~s"
                     (and c4-desc #t) (buffer->string c4)))
  (displayln (format "⑤ patch 写 diag   (0,1)=~a  content 换了吗？~a ← 写标注不换 content"
                     (buffer-get-property p0 0 1 'diag) (not (buffer-content-same? b0 p0))))
  (displayln (format "   同 key 空 patch  (0,1)=~a                ← 清旧" (buffer-get-property p1 0 1 'diag)))
  (displayln (format "   两个 key 并存    face=~a diag=~a   ← 不同插件互不干扰"
                     (buffer-get-property p2 0 1 'face) (buffer-get-property p2 0 1 'diag))))

;;; ---------- 测试 ----------

(module+ test
  ;; ① 写与读：同 key 按位置切开；没写过的 key 是 #f
  (check-equal? (face b1 0 3) 'bold)
  (check-equal? (face b3 0 1) 'red)
  (check-equal? (face b3 0 3) 'underline)
  (check-equal? (face b3 0 4) 'bold)                  ; 切开后 [4,5) 仍是 bold
  (check-equal? (face b3 1 2) 'italic)
  (check-equal? (buffer-get-property b3 0 1 'diag) #f)

  ;; 清一个 key：只清它，别的 key 不动
  (check-equal? (face b3-none 0 2) #f)

  ;; ② 编辑时自动跟随：整行右移一位，新字符无 face
  (check-equal? (buffer->string b4) "Xhello\nworld")
  (check-equal? (face b4 0 1) 'red)
  (check-equal? (face b4 0 2) 'red)
  (check-equal? (face b4 0 0) #f)
  (check-equal? (face b4 0 5) 'bold)                  ; 原 [4,5) → [5,6)

  ;; ③ 行合并：行 1 的属性跟到行 0 来
  (check-equal? (buffer->string b5) "Xhelloworld")
  (check-equal? (face b5 0 7) 'italic)

  ;; ④ 约束槽：零宽插入点落在只读区间内 → 整个编辑被拒（desc = #f，文本不动）
  (check-true (buffer-read-only-at? c0 0 2))
  (check-false (buffer-read-only-at? c0 0 0))
  (check-false c1-desc)
  (check-equal? (buffer->string c1) "hello\nworld")
  (check-equal? (buffer->string c2) "hellXo\nworld")  ; (0,4) 在 [1,4) 之外
  (check-equal? (buffer->string c4) "hXello\nworld")  ; 清除约束后可编辑

  ;; ⑤ patch：按 key 清旧写新；写标注不动 content（异步失效判定靠它）
  (check-equal? (buffer-get-property p0 0 1 'diag) "err")
  (check-true (buffer-content-same? b0 p0))
  (check-false (buffer-get-property p1 0 1 'diag))
  (check-equal? (buffer-get-property p2 0 1 'face) 'bold)
  (check-equal? (buffer-get-property p2 0 1 'diag) "err")
  ;; 过期 patch（行范围越界）→ 报错，绝不静默写到别的行上
  (check-exn exn:fail? (lambda () (buffer-apply-patches b0 (list (patch 'diag 0 99 '())))))

  (displayln "attributes.rkt: all tests passed"))