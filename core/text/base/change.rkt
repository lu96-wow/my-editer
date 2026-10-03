#lang racket

(require "point.rkt" "range.rkt")

;;; base/change.rkt —— 一次编辑的变更描述
;;;
;;; change = {before, after}，两个**点区间**：
;;;     before   被替换的区间（**编辑前**坐标）
;;;     after    替换后的区间（**编辑后**坐标）
;;;
;;; 只存**结构**（两个区间），**不存文本内容**：
;;;     · 位置映射只需行结构，after 已编码（首行 / 末行的行列）；
;;;     · 文本内容用时从**新文档**的 after 区间取（document-change-text）。
;;;
;;; before 用来区分「删除」和「无操作」（删除的 after 是零宽），也用于重基准
;;; （旧位置现在在哪）。
;;;
;;; 两类用途，坐标相反：
;;;     重基准（选区 / marker）   change-map-point     before → after
;;;     失效（高亮 / 渲染）       change-post-range    直接读 after（当前坐标的脏区 seed）

(provide
 ;; ---------- 类型 ----------
 (struct-out change)

 ;; ---------- 读 ----------
 change-empty? change-kind change-post-range

 ;; ---------- 映射（重基准） ----------
 change-map-point
 changes-map-point changes-map-point-literal)

(struct change (before after) #:transparent)
;; before / after : range
;; before 非空 = 删过东西；after 非空 = 插了东西。两者都空 = 无操作。

;; 当前（编辑后）坐标的区间 = 失效用脏区 seed。
(define (change-post-range ch) (change-after ch))

(define (change-empty? ch)
  (and (range-empty? (change-before ch)) (range-empty? (change-after ch))))

;; 'none / 'insert / 'delete / 'replace
(define (change-kind ch)
  (define b? (not (range-empty? (change-before ch))))
  (define a? (not (range-empty? (change-after ch))))
  (cond [(and b? a?) 'replace] [b? 'delete] [a? 'insert] [else 'none]))

;;; ---------- 映射：编辑前位置 → 编辑后位置 ----------

;; 单个 change 把编辑前位置 p 映射到编辑后位置；#f = p 落在**被删区间内部**。
;; 只用两端的行结构，不需要文本内容：
;;     p ≤ before.start              → 不动
;;     before.start < p < before.end → #f（落在删除段）
;;     p ≥ before.end                → 平移 Δline = after.end.line - before.end.line
(define (change-map-point ch p)
  (define b (change-before ch)) (define a (change-after ch))
  (define bs (range-start b)) (define be (range-end b))
  (define ae (range-end a))
  (cond
    [(point<=? p bs) p]
    [(point<? p be) #f]
    [else
     (cond
       [(= (point-line p) (point-line be))
        (point (point-line ae) (+ (point-column ae) (- (point-column p) (point-column be))))]
       [else
        (point (+ (point-line p) (- (point-line ae) (point-line be))) (point-column p))])]))

;; 一组 change（**同一编辑前坐标系**、两两不重叠）从右往左依次映射 p。
;; 从右往左：右侧 change 只对「已在其右侧」的点生效，不会污染与左侧 change 的比较。
;; 前进语义（光标）：恰在某零宽插入的起点 → 落到插入文本之后；
;;                   落在某段被删区间内 → 吸附到该段起点。
(define (changes-map-point changes p)
  (for/fold ([p p]) ([ch (in-list (changes-right-to-left changes))])
    (cond
      [(and (point=? p (range-start (change-before ch)))
            (range-empty? (change-before ch)))
       (range-end (change-after ch))]
      [else (or (change-map-point ch p) (range-start (change-before ch)))])))

;; 同上，但**字面**语义：恰在零宽插入的起点 → 不动（不跟随插入）。
;; 用于「非编辑者视图」的选区重基准。
(define (changes-map-point-literal changes p)
  (for/fold ([p p]) ([ch (in-list (changes-right-to-left changes))])
    (or (change-map-point ch p) (range-start (change-before ch)))))

(define (changes-right-to-left changes)
  (sort changes (lambda (a b) (point<? (range-start (change-before b))
                                       (range-start (change-before a))))))
