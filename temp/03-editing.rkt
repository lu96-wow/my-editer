#lang racket
;;; 03 —— 编辑：纯算子 + 提交 + 多光标 + 只读守卫
;;;
;;; 运行：racket temp/03-editing.rkt
;;;
;;; 模式：操作 = 纯函数（edit-op），提交 = buffer-edit!（写回 + 记 history + rebase 兄弟）。
;;; 合并完全显式：buffer-edit! 每次调用 = 一个新撤销步；要合并用事务（见 05 / 10）。
;;; 只读守卫：编辑前检查区间，命中只读格 → 整体拒绝，返回 #f。
;;;
;;; 注意：只读/face 的写回用 *-line! / *-range! / *-cell!（会按需建轨）。
;;;       「整条轨替换」（吃 track 的 buffer-set-readonly!/buffer-set-face!）和
;;;       edit-op 都是内部机制，使用层（editor.rkt）不导出。

(require "../core/editor.rkt")

(define b (make-buffer "hello\nworld"))
(define v (buffer-add-view! b 40 10))

(define (title s) (printf "\n==== ~a ====\n" s))

(title "每次 buffer-edit! = 一个撤销步（无隐式合并）")
(view-set-point! v (point 0 5))          ; 行尾
(void (buffer-edit! b v (op-type "!")))
(void (buffer-edit! b v (op-type "?")))
(printf "内容: ~s  undo 步数: ~a（两下 = 两步）\n" (buffer-string b) (buffer-depth b))

(title "粘贴 / 退格 / 前向删除")
(view-set-point! v (point 1 0))
(void (buffer-edit! b v (op-paste ">> ")))
(printf "粘贴后: ~s\n" (buffer-string b))
(void (buffer-edit! b v (op-backspace)))
(void (buffer-edit! b v (op-delete)))
(printf "退格+删除后: ~s\n" (buffer-string b))

(title "要合并：用一个事务把多次提交合成一步")
(define b6 (make-buffer "abc"))
(define v6 (buffer-add-view! b6 40 10))
(void (buffer-with-undo-step b6
  (lambda ()
    (buffer-edit! b6 v6 (op-type "1"))
    (buffer-edit! b6 v6 (op-type "2"))
    (buffer-edit! b6 v6 (op-type "3")))))
(printf "内容: ~s  undo 步数: ~a（三次提交 = 一步）\n" (buffer-string b6) (buffer-depth b6))

(title "只读守卫：命中只读 → 整体拒绝（返回 #f）")
(buffer-readonly-line! b 0 #t)           ; 第 0 行整行只读
(printf "readonly@(0,0)=~a  (1,0)=~a\n"
        (buffer-readonly-at? b 0 0) (buffer-readonly-at? b 1 0))
(view-set-point! v (point 0 0))
(printf "只读行普通编辑   ret = ~a（#f = 拒绝）\n"
        (buffer-edit! b v (op-type "x")))
(printf "只读行 ignore 编辑 changes = ~a 个\n"
        (length (buffer-edit! b v (op-type-ignore-readonly "x"))))
(view-set-point! v (point 1 0))
(printf "可写行编辑       changes = ~a 个\n"
        (length (buffer-edit! b v (op-type "y"))))
(printf "内容: ~s\n" (buffer-string b))

(title "拿 changes：buffer-edit! 返回本次变更描述")
(define b4 (make-buffer "abcdef"))
(define v4 (buffer-add-view! b4 40 10))
(view-set-selections! v4 (selections-one (selection (point 0 1) (point 0 4))))  ; "bcd"
(define chs (buffer-edit! b4 v4 (op-type "X")))
(printf "内容: ~s  changes = ~a 个\n" (buffer-string b4) (length chs))
(for ([ch (in-list chs)])
  (printf "  kind=~a before=~a after=~a 插入文本=~s\n"
          (change-kind ch)
          (change-before ch) (change-after ch)
          (buffer-range-text b4 (change-after ch))))

;; 无变更 → '()（真值，但空表）
(define b5 (make-buffer "abc"))
(define v5 (buffer-add-view! b5 40 10))
(printf "文首退格 ret = ~a（'() = 提交成功但无变更）\n"
        (buffer-edit! b5 v5 (op-backspace)))

(title "多光标：一条编辑施加到所有选区")
(define b2 (make-buffer "aaa\nbbb\nccc"))
(define v2 (buffer-add-view! b2 40 10))
(view-set-selections! v2
  (selections-of (list (caret (point 0 0))
                       (caret (point 1 0))
                       (caret (point 2 0)))
                 0))
(printf "编辑前:\n~a\n" (buffer-string b2))
(void (buffer-edit! b2 v2 (op-type "-")))
(printf "行首同时插入后:\n~a\n" (buffer-string b2))
(printf "各选区（每行插入点之后）: ~a\n"
        (map (lambda (s) (call-with-values (lambda () (selection-range s)) list))
             (selections-items (view-selections v2))))

(title "选区被替换：选中再打字")
(define b3 (make-buffer "foo bar baz"))
(define v3 (buffer-add-view! b3 40 10))
(view-set-selections! v3 (selections-one (selection (point 0 4) (point 0 7))))  ; "bar"
(void (buffer-edit! b3 v3 (op-type "QUX")))
(printf "内容: ~s\n" (buffer-string b3))
