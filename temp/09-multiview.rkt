#lang racket
;;; 09 —— 一份文档、多个 view：编辑时兄弟视图自动重基准
;;;
;;; 运行：racket temp/09-multiview.rkt
;;;
;;; 发起编辑的 view：选区前进（放到新光标）。
;;; 兄弟 view：用本次 changes 做 selections-rebase（字面），各自平移选区。
;;; 共享一份 history：undo/redo 影响所有 view，随后统一 clamp。

(require "../core/editor.rkt"
         "../core/text/rebase.rkt")   ; selections-rebase / selections-advance

(define b (make-buffer "alpha\nbravo\ncharlie"))
(define v1 (buffer-add-view! b 40 10))   ; 发起编辑
(define v2 (buffer-add-view! b 40 10))   ; 兄弟视图

(define (title s) (printf "\n==== ~a ====\n" s))

(title "编辑前")
(view-set-point! v1 (point 1 0))
(view-set-point! v2 (point 1 5))          ; "bravo" 行尾
(printf "v1=~a  v2=~a\n" (view-point v1) (view-point v2))

(title "在 v1 行首插入，兄弟 v2 自动 rebase")
(void (buffer-edit! b v1 (op-type ">> ")))
(printf "文档:\n~a\n" (buffer-string b))
(printf "v1（发起）光标=~a\n" (view-point v1))
(printf "v2（兄弟）光标=~a  <- 由 (1,5) 右移到 (1,8)\n" (view-point v2))

(title "共享一份 history：undo 影响所有 view")
(void (buffer-undo! b))
(printf "undo 后文档: ~s\n" (buffer-string b))
(printf "v1=~a  v2=~a（都夹回合法域）\n" (view-point v1) (view-point v2))

(title "直接重基准：selections-rebase（字面） vs selections-advance（前进）")
;; 构造一次「在 (0,0) 插入 3 个字符」的变更
(define ch (change (range-of (point 0 0) (point 0 0))     ; before：零宽
                   (range-of (point 0 0) (point 0 3))))   ; after：插入 3 字

(define after-insert (selections-one (caret (point 0 2))))  ; 光标在插入点之后
(printf "原始选区: ~a\n"
        (call-with-values (lambda () (selection-range (selections-primary after-insert))) list))
(printf "rebase 后（字面：端点随编辑平移）: ~a\n"
        (call-with-values
         (lambda () (selection-range (selections-primary (selections-rebase (list ch) after-insert))))
         list))

;; 恰在零宽插入点上：字面不动，前进落到插入之后
(define at-insert (selections-one (caret (point 0 0))))
(printf "恰在插入点上：literal=~a  advance=~a\n"
        (call-with-values
         (lambda () (selection-range (selections-primary (selections-rebase (list ch) at-insert))))
         list)
        (call-with-values
         (lambda () (selection-range (selections-primary (selections-advance (list ch) at-insert))))
         list))
