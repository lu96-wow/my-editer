#lang racket
;;; 02 —— 选区：值层构造 + 提交到 view + 查询（增 / 删 / 查）
;;;
;;; 运行：racket temp/02-selection.rkt
;;;
;;; 两层分工：
;;;   值层 selection.rkt   造 / 改 selection、selections 值（纯）
;;;   提交层 ops.rkt       把值写回 view，顺便 clamp + 保证可见
;;;
;;; 没有 view-add-selection! / view-remove-selection!，改选区一律：
;;;   (view-set-selections! v <纯变换 (view-selections v)>)

(require "../core/editor.rkt")

(define b (make-buffer "alpha\nbravo\ncharlie\ndelta"))
(define v (buffer-add-view! b 40 10))

(define (title s) (printf "\n==== ~a ====\n" s))

;;; ---------- 值层 ----------

(title "值层：point / caret / selection / selections")
(define p0 (point 0 0))
(define c0 (caret p0))                              ; 空选区 = 光标
(define sel (selection (point 1 0) (point 1 5)))    ; anchor, head → 选中 "bravo"
(printf "caret 空? ~a\n" (caret? c0))
(printf "sel 区间: ~a\n"
        (call-with-values (lambda () (selection-range sel)) list))

;;; ---------- 增 ----------

(title "增：造集合 + 追加 + 写回")
(view-set-selections! v (selections-one c0))
(view-set-selections! v
  (selections-add (view-selections v) (list sel)))  ; read-modify-write
(printf "选区数: ~a\n" (view-selection-count v))
(printf "items:\n")
(for ([s (in-list (selections-items (view-selections v)))] [i (in-naturals)])
  (printf "  [~a] range=~a empty?=~a primary?=~a\n"
          i
          (call-with-values (lambda () (selection-range s)) list)
          (selection-empty? s)
          (= i (selections-primary-index (view-selections v)))))

;;; ---------- 查 ----------

(title "查：view 层")
(printf "view-selections        → ~a 个\n" (view-selection-count v))
(printf "view-primary-range     → ~a\n" (view-primary-range v))
(printf "view-point             → ~a\n" (view-point v))
(printf "view-point-line/column → ~a / ~a\n" (view-point-line v) (view-point-column v))

;;; ---------- 改 primary ----------

(title "改 primary（不是增删，但常一起用）")
(view-set-selections! v (selections-set-primary (view-selections v) 1))
(printf "primary 现为 index=~a range=~a\n"
        (selections-primary-index (view-selections v))
        (view-primary-range v))

;;; ---------- 删 ----------

(title "删：移除一项（删空则原样，保 ≥1）")
(view-set-selections! v
  (selections-remove (view-selections v) (list (view-primary v))))
(printf "删后选区数: ~a\n" (view-selection-count v))

;;; ---------- 定位 / 全选 ----------

(title "定位 / 全选（选区坍缩、覆盖）")
(view-select-all! v)
(printf "全选 range: ~a\n" (view-primary-range v))
(view-set-point! v (point 2 3))
(printf "定位 (2,3) 后: ~a  选区数=~a\n"
        (view-point v) (view-selection-count v))

;;; ---------- 归一 ----------

(title "去重 / 排序合并")
(define messy
  (selections-of (list (selection (point 1 0) (point 1 5))    ; bravo
                       (selection (point 1 2) (point 1 4))    ; 落在上一项内部
                       (selection (point 1 0) (point 1 5)))   ; 完全重复
                 0))
(view-set-selections! v (selections-normalize messy))
(printf "归一后选区数: ~a（重复删除、重叠合并）\n" (view-selection-count v))
