#lang racket

;;; attributes.rkt —— 属性的修改：写 / 读 / 清 / 只读约束 / 编辑时自动跟随 / 程序修改 / patch
;;;
;;; 三个要点：
;;;   1. 属性按**位置**存在按行切分的 span 里，**编辑时自动跟着文本移动**
;;;      （`buffer-edit-at` 这个唯一漏斗里就调 properties-apply-edit）——写一次，之后不用管。
;;;   2. **表现层（face）与约束（read-only）是两个槽**：前者是样式，后者是编辑器语义。
;;;      约束是**逐行**存的（`buffer-put-restrict` 只作用于一行），跨行区间要逐行设。
;;;   3. 只读挡住的是**用户编辑**；程序要改它必须走**显式 trusted 入口**——没有全局开关、
;;;      没有隐式绕行（ARCHITECTURE §8.8）。而 trusted 写进去的新文本**不带**原约束。
;;;
;;; 必要 API：
;;;   写    buffer-put-property        buffer-put-properties-many    buffer-remove-property
;;;   读    buffer-get-property        buffer-line-ref
;;;   约束  buffer-put-restrict        make-restrict                buffer-read-only-at?
;;;         buffer-restrict-runs                                   （枚举只读区间）
;;;   程序  buffer-splice-trusted      buffer-apply-edit-trusted    buffer-apply-edit
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

;;; ---------- 4. 只读约束：设 / 查 / 用户编辑被拒 / 清 ----------

(define ro0 (buffer-open "hello\nworld\nfoo"))

;; 设：行 0 的 [1,4) 只读（约束是**逐行**的，(line start end) 都指同一行）
(define c0 (buffer-put-restrict ro0 0 1 4 (restrict #t)))

;; 查：注意 [1,4) 是**半开**区间 —— (0,4) 已经在区间外
;; （区间的构造在 core 里也会夹紧，不会越界）

;; 跨行整段只读：约束逐行存，所以逐行设（这里要读行长 → buffer-line-ref）
(define (put-read-only-range b s-line s-col e-line e-col)
  (for/fold ([x b]) ([ln (in-range s-line (add1 e-line))])
    (buffer-put-restrict x ln
                         (if (= ln s-line) s-col 0)
                         (if (= ln e-line) e-col (string-length (buffer-line-ref x ln)))
                         (restrict #t))))
;; 行 1 的 [2,5) ＋ 行 2 的 [0,1) 一起只读
(define c5 (put-read-only-range ro0 1 2 2 1))

;; 用户编辑被拒：零宽插入点落在只读区间**内** → 整个编辑不发生（desc = #f，文本不动）
(define-values (c1 c1-desc) (buffer-insert-char c0 0 1 #\X))
;; 紧贴区间右边界（已在区间外）→ 允许
(define-values (c2 c2-desc) (buffer-insert-char c0 0 4 #\X))

;; 清：传空约束即清除该区间的约束
(define c3 (buffer-put-restrict c0 0 1 4 (make-restrict)))
(define-values (c4 c4-desc) (buffer-insert-char c3 0 1 #\X))   ; 清除后同一点就能编辑

;;; ---------- 5. 程序修改：跳过守卫的显式入口 ----------
;;; 上面挡住的是**用户编辑**。程序（格式化、重构、撤销/重放）要改只读内容，走
;;; `-trusted` 入口——显式到调用点，没有全局开关，也没有隐式绕行（ARCHITECTURE §8.8）。
;;; 两条路同形，只差一个名字，所以"谁在绕守卫"在调用点一眼可见。

;; 显式坐标那一对
(define-values (g1 g1-desc) (buffer-splice c0 0 1 0 4 "XX"))          ; 过守卫 → 拒
(define-values (g2 g2-desc) (buffer-splice-trusted c0 0 1 0 4 "XX"))  ; trusted → 改
;; desc 形状那一对
(define g-desc (edit-desc 0 1 0 4 "YY"))
(define-values (h1 h1-desc) (buffer-apply-edit c0 g-desc))            ; 过守卫 → 拒
(define-values (h2 h2-desc) (buffer-apply-edit-trusted c0 g-desc))    ; trusted → 改

;; ⚠️ trusted 写进去的**新文本不带**原约束：被替换的只读区间随删除塌缩，约束消失
;; （属性是随编辑**映射**过去的，不会凭空长到新文本上）。

;; 所以要"替换后仍只读"，得先**读出**原来的约束区间、再显式设到新文本上。
;; `buffer-restrict-runs` 给的是**区间**（`buffer-read-only-at?` 只能逐点问）：
;; 行 0 得到 ((0 1 空约束) (1 4 只读) (4 5 空约束)) → 只读段是 [1,4)。
(define ro-runs (buffer-restrict-runs c0 0))
;; 搬运：新文本 [1,3) 重新设上只读（这就是"程序替换一段只读内容"的正确姿势）
(define g2-ro (buffer-put-restrict g2 0 1 3 (restrict #t)))

;;; ---------- 6. patch：插件输出 = delta（按 key 清旧写新）----------

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
  (displayln (format "④ 只读 [1,4)      (0,1)=~a (0,2)=~a (0,4)=~a  ← 半开区间，右边界在外"
                     (buffer-read-only-at? c0 0 1) (buffer-read-only-at? c0 0 2)
                     (buffer-read-only-at? c0 0 4)))
  (displayln (format "   跨行整段只读     (1,2)=~a (1,1)=~a (2,0)=~a (2,1)=~a"
                     (buffer-read-only-at? c5 1 2) (buffer-read-only-at? c5 1 1)
                     (buffer-read-only-at? c5 2 0) (buffer-read-only-at? c5 2 1)))
  (displayln (format "   用户插在 (0,1)   desc=~a 文本=~s   ← 区间内：被拒"
                     c1-desc (buffer->string c1)))
  (displayln (format "   用户插在 (0,4)   desc非#f？~a 文本=~s ← 区间外：允许"
                     (and c2-desc #t) (buffer->string c2)))
  (displayln (format "   清除约束后插      desc非#f？~a 文本=~s" (and c4-desc #t) (buffer->string c4)))
  (displayln (format "⑤ 程序改 [1,4)    守卫版 desc=~a；trusted 版 desc非#f？~a → ~s"
                     g1-desc (and g2-desc #t) (buffer->string g2)))
  (displayln (format "   desc 形状那一对  守卫版 desc=~a；trusted 版 desc非#f？~a → ~s"
                     h1-desc (and h2-desc #t) (buffer->string h2)))
  (displayln (format "   改完约束还在吗？  (0,1)=~a  ← 新文本不带原约束（区间塌缩）"
                     (buffer-read-only-at? g2 0 1)))
  (displayln (format "   读回只读区间      ~a   ← 从 runs 筛 restrict-read-only?"
                     (for/list ([seg (in-list ro-runs)]
                                #:when (restrict-read-only? (caddr seg)))
                       (list (car seg) (cadr seg)))))
  (displayln (format "   搬运到新文本      ~a   ← 替换后重新设上"
                     (for/list ([seg (in-list (buffer-restrict-runs g2-ro 0))]
                                #:when (restrict-read-only? (caddr seg)))
                       (list (car seg) (cadr seg)))))
  (displayln (format "⑥ patch 写 diag   (0,1)=~a  content 换了吗？~a ← 写标注不换 content"
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

  ;; ④ 只读：半开区间、逐行设、用户编辑被拒、可清除
  (check-true (buffer-read-only-at? c0 0 1))
  (check-true (buffer-read-only-at? c0 0 3))
  (check-false (buffer-read-only-at? c0 0 4))         ; 右边界在区间外
  (check-false (buffer-read-only-at? c0 0 0))         ; 左边界在区间外
  ;; 跨行整段：行 1 的 [2,5) ＋ 行 2 的 [0,1)
  (check-true (buffer-read-only-at? c5 1 2))
  (check-true (buffer-read-only-at? c5 1 4))
  (check-false (buffer-read-only-at? c5 1 1))
  (check-true (buffer-read-only-at? c5 2 0))
  (check-false (buffer-read-only-at? c5 2 1))
  ;; 零宽插入点落在区间内 → 整个编辑被拒（desc = #f，文本不动）
  (check-false c1-desc)
  (check-equal? (buffer->string c1) "hello\nworld\nfoo")
  (check-equal? (buffer->string c2) "hellXo\nworld\nfoo")   ; (0,4) 在区间外
  (check-equal? (buffer->string c4) "hXello\nworld\nfoo")   ; 清除约束后可编辑

  ;; ⑤ 程序修改：守卫版拒、trusted 版改；两条路同形
  (check-false g1-desc)
  (check-equal? (buffer->string g1) "hello\nworld\nfoo")
  (check-equal? (buffer->string g2) "hXXo\nworld\nfoo")
  (check-false h1-desc)
  (check-equal? (buffer->string h1) "hello\nworld\nfoo")
  (check-equal? (buffer->string h2) "hYYo\nworld\nfoo")
  ;; trusted 写进去的新文本**不带**原约束（被替换的只读区间随删除塌缩）
  (check-false (buffer-read-only-at? g2 0 1))
  (check-false (buffer-read-only-at? h2 0 1))
  ;; 枚举只读区间：形状 (list start end restrict)，恰好覆盖整行、相邻段必不同
  (check-equal? (buffer-restrict-runs c0 0)
                (list (list 0 1 (make-restrict)) (list 1 4 (restrict #t)) (list 4 5 (make-restrict))))
  (check-equal? (for/list ([seg (in-list (buffer-restrict-runs c0 0))]
                           #:when (restrict-read-only? (caddr seg)))
                  (list (car seg) (cadr seg)))
                (list (list 1 4)))                                   ; 唯一的只读段
  (check-equal? (buffer-restrict-runs ro0 0)                         ; 没设过 → 整行空约束
                (list (list 0 5 (make-restrict))))
  ;; 搬运：把读到的范围设到新文本上（"程序替换一段只读内容"的完整姿势）
  (check-equal? (for/list ([seg (in-list (buffer-restrict-runs g2-ro 0))]
                           #:when (restrict-read-only? (caddr seg)))
                  (list (car seg) (cadr seg)))
                (list (list 1 3)))

  ;; ⑥ patch：按 key 清旧写新；写标注不动 content（异步失效判定靠它）
  (check-equal? (buffer-get-property p0 0 1 'diag) "err")
  (check-true (buffer-content-same? b0 p0))
  (check-false (buffer-get-property p1 0 1 'diag))
  (check-equal? (buffer-get-property p2 0 1 'face) 'bold)
  (check-equal? (buffer-get-property p2 0 1 'diag) "err")
  ;; 过期 patch（行范围越界）→ 报错，绝不静默写到别的行上
  (check-exn exn:fail? (lambda () (buffer-apply-patches b0 (list (patch 'diag 0 99 '())))))

  (displayln "attributes.rkt: all tests passed"))