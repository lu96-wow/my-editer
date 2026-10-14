#lang racket
;;; 01 —— buffer / view 对象：创建、共享、关闭
;;;
;;; 运行：racket temp/01-objects.rkt
;;;
;;; 架构要点（README 锁定决策 1）：
;;;   · 没有 did/vid，身份 = 对象本身；宿主持有对象。
;;;   · buffer = 一份内容 + history + 它的所有 view。
;;;   · view   = 一块显示状态（viewport + selections），指回 buffer。
;;;   · 存在集 buffer.views（core 维护）≠ 可见集 宿主 layout（见 08-render）。

(require "../core/editor.rkt")

(define (title s) (printf "\n==== ~a ====\n" s))

(title "建 buffer")
(define b (make-buffer "hello\nworld" "main.rkt"))
(printf "名字: ~a\n" (buffer-name b))
(printf "内容: ~s\n" (buffer-string b))
(printf "初始 view 数: ~a\n" (length (buffer-views b)))

(title "挂 view（登记进存在集 buffer.views）")
(define v1 (buffer-add-view! b 40 10))
(define v2 (buffer-add-view! b 40 10
             #:mode 'wrap
             #:line-numbers? #t
             #:selections (selections-one (caret (point 1 0)))))
(printf "view 数: ~a\n" (length (buffer-views b)))
(printf "v1 光标: ~a\n" (view-point v1))
(printf "v2 光标: ~a  mode: ~a\n" (view-point v2) (view-mode v2))

(title "一份 document + 一份 history，被两个 view 共享")
(printf "v1/v2 指向同一 buffer? ~a\n" (eq? (view-buffer v1) (view-buffer v2)))
(printf "v1/v2 document 同一对象? ~a\n" (eq? (view-document v1) (view-document v2)))
(printf "编辑 v1，v2 也会看到：\n")
(view-set-point! v1 (point 0 5))
(void (buffer-edit! b v1 (op-type "!")))
(printf "  文档: ~s\n" (buffer-string b))

(title "隐藏 vs 销毁（README「存在集 vs 可见集」）")
;; 隐藏 = 只从宿主 layout 摘掉，view 仍在 buffer.views —— 这里用不到 core API
;; 销毁 = 从存在集摘掉
(buffer-close-view! b v2)
(printf "销毁 v2 后 view 数: ~a\n" (length (buffer-views b)))

(title "关文档：解除与所有 view 的关联")
(buffer-close! b)
(printf "关后 view 数: ~a\n" (length (buffer-views b)))
