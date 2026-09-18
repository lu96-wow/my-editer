#lang racket

(require "core/api.rkt" "history.rkt" rackunit)

;;; document-layer.rkt —— **document 层**的机制示例（不拼编辑器、不接前端）
;;;
;;; 这个文件只为摆清一条边界：**document 不自动记 history**。
;;;
;;; document 层会给你（`document-edit-reversible`）：
;;;     新 document ＋ 这次编辑的 desc ＋ 逆 inv ＋ 编辑前光标 pre-point
;;;   —— 即"把捕获的材料**备齐**"，但它**不**决定入不入栈、**不**知道"什么算一步"，
;;;      更**没有** undo 这个操作。
;;; 记账（栈、分组、撤销/重放）在消费层 `history.rkt`：它不认识 document，只认识 desc 和 point。
;;;
;;; 下面 A / B 两段的 **document 层调用逐字相同**，唯一差别是 B 多了一行把返回值存进账本。
;;; 跑 `racket document-layer.rkt` 看输出；`module+ test` 里那条 `(check-equal? a1 b1)`
;;; 就是"document 的值里没有记账痕迹"的证明。

;; 一个 document + 一个视图（视图光标放在 col，方便示例从行中间插入）
(define (fresh text [col 0])
  (define-values (doc i)
    (document-add-view (document-of-buffer (buffer-open text)) (make-window 3 20)
                       (point 0 col)))
  (values doc i))

;; 一次编辑（buffer 级 edit-fn —— 这是 document-edit 的契约形状）
(define (ins-fn s) (lambda (b l c) (buffer-insert-string b l c s)))

;;; ---------- A) 只调 document 层：编辑生效，但没有账本 ----------

(define-values (a0 ai) (fresh "abc" 1))
(define-values (a1 a-desc a-inv a-p0)
  (document-edit-reversible a0 ai (ins-fn "XY")))

(displayln "A) 只调 document 层")
(displayln (format "   文本      ~a" (buffer->string (document-buffer a1))))
(displayln (format "   desc      ~a" a-desc))
(displayln (format "   逆 inv    ~a      ← document 把逆也备好了" a-inv))
(displayln (format "   编辑前光标 ~a" a-p0))
(displayln "   → 但没人存过它们：document 里没有 undo 这个操作。")

;;; ---------- B) 同一个 document 层调用 ＋ 一行消费层记账 ----------

(define-values (b0 bi) (fresh "abc" 1))
(define b-hist0 (make-history))
(define-values (b1 b-desc b-inv b-p0)
  (document-edit-reversible b0 bi (ins-fn "XY")))
;; ↓↓↓ 记账：**消费层的动作**（document 层不知道有这一步）
(define b-hist1 (history-record b-hist0 b-desc b-inv b-p0))

;; 撤销：账本给 step；desc 通过 document 的 desc 形状入口落回视图，再收光标/对齐 follow
(define-values (b-step b-hist2) (history-pop-undo b-hist1))
(define b2 (for/fold ([d b1]) ([x (in-list (step-undo-descs b-step))])
             (define-values (d* _) (document-apply-edit-trusted d bi x)) d*))
(define b3 (document-update-view-synced b2 bi
             (lambda (w) (window-ensure-point (window-set-point w (step-point b-step))))))

(displayln "\nB) 同一段 document 调用 ＋ 一行 history-record")
(displayln (format "   编辑后    ~a" (buffer->string (document-buffer b1))))
(displayln (format "   撤销后    ~a      ← 文本回来了，光标也回到 ~a"
                   (buffer->string (document-buffer b3)) (window-point (document-window b3 bi))))
(displayln (format "   账本深度  撤销 ~a → ~a" (history-undo-depth b-hist1) (history-undo-depth b-hist2)))
(displayln "   → 差别只有那一行；document 层两段完全一样。")

;;; ---------- 测试 ----------

(module+ test
  ;; A 段：编辑确实生效（并且逆确实是"抵消这次编辑"的那条 desc）
  (check-equal? (buffer->string (document-buffer a1)) "aXYbc")
  (check-equal? a-desc (edit-desc 0 1 0 1 "XY"))
  (check-equal? a-inv (edit-desc 0 1 0 3 ""))
  (check-equal? a-p0 (point 0 1))

  ;; **核心证据**：同样一次编辑，记不记账，document 的值**完全相同**
  ;; ⇒ document 里没有任何记账痕迹（它只有 buffer + views 两个字段）
  (check-equal? a1 b1)

  ;; B 段：记账后才有撤销；撤销精确回到编辑前（文本 + 光标）
  (check-equal? (buffer->string (document-buffer b3)) "abc")
  (check-equal? (window-point (document-window b3 bi)) a-p0)
  (check-equal? (history-undo-depth b-hist1) 1)
  (check-equal? (history-undo-depth b-hist2) 0)
  (check-equal? (history-redo-depth b-hist2) 1)

  ;; 逆 desc 与 document 的 desc 形状入口配合：撤销就是"把 inv 当 desc 施加"
  (check-equal? (buffer->string (document-buffer b2)) "abc")

  (displayln "document-layer.rkt: all tests passed"))