#lang racket

(require "../../text/base/width.rkt")

;;; screen.rkt —— 屏幕帧（后端无关）
;;;
;;; 一帧 = 若干行文本（同 face 的连续段 = **run**）+ 光标 + 选中区（都是**显示列**坐标）。
;;;   run     一行里一段同 face 的文本（col 是显示列）
;;;   cursor  光标点（视图 overlay）
;;;   region  选中区段（一个跨行选区在每行切一段）
;;; face 是不透明值（core 不解释），来自高亮轨。
;;;
;;; 坐标词汇：屏幕空间一律 **row / col**（col = 显示列）。
;;; run.col 是行内列；cursor/region、pane、rectangle 都用 **(row, col)（先行再列）**。
;;;
;;; 名字约定：`seg` 在 view 里专指**显示列区间**（layout/width 用）；屏幕上的文本段叫 `run`。

(provide
 ;; ---------- 类型 ----------
 (struct-out run)
 (struct-out cursor)
 (struct-out region)
 (struct-out screen)

 ;; ---------- 读 ----------
 screen-row screen->string)

(struct run (column text face) #:transparent)
;; col : 显示列（0-based，行内）；text : 不含换行；face : any/c（#f = 无）

(struct cursor (row column primary?) #:transparent)
(struct region (row start-column end-column primary?) #:transparent)

(struct screen (width height rows cursors regions) #:transparent)
;; rows : (vectorof (listof run))   长度 = height
;; cursors / regions : overlay（已换算到屏幕坐标）

(define (screen-row s r)
  (unless (and (exact-nonnegative-integer? r) (< r (screen-height s)))
    (error 'screen-row "行号越界: ~a（共 ~a 行）" r (screen-height s)))
  (vector-ref (screen-rows s) r))

;; 一帧的纯文本（run 间空隙补空格、行尾裁掉）。给测试 / 文本后端用。
(define (screen->string s)
  (string-join
   (for/list ([r (in-range (screen-height s))])
     (define out (open-output-string))
     (define col 0)
     (for ([rn (in-list (screen-row s r))])
       (define txt (run-text rn))
       (when (> (run-column rn) col) (display (make-string (- (run-column rn) col) #\space) out))
       (display txt out)
       (set! col (+ (run-column rn) (string-display-width txt))))
     (get-output-string out))
   "\n"))
