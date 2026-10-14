#lang racket
;;; 05 —— 历史：undo / redo / 并步 / 记步开关
;;;
;;; 运行：racket temp/05-history.rkt
;;;
;;; history = 纯文档版本栈（past / current / future）。没有 who/selections。
;;; 并步（merge）由提交层决定：同一 tag、同一 view、选区未变 → 折叠进当前步。
;;; buffer-end-undo-step!（原实现名 buffer-seal!）切断后续并步（下一个编辑新起一步）。

(require "../core/editor.rkt")

(define b (make-buffer "one\ntwo"))
(define v (buffer-add-view! b 40 10))

(define (title s) (printf "\n==== ~a ====\n" s))

(title "连续打字并成一步")
(view-set-point! v (point 0 3))
(void (buffer-edit! b v (op-type "!")))
(void (buffer-edit! b v (op-type "?")))
(printf "内容: ~s  undo 步数: ~a\n" (buffer-string b) (buffer-depth b))

(title "seal 切断并步")
(buffer-end-undo-step! b)
(view-set-point! v (point 1 3))
(void (buffer-edit! b v (op-type ".")))
(printf "内容: ~s  undo 步数: ~a\n" (buffer-string b) (buffer-depth b))

(title "undo / redo")
(printf "can-undo?=~a can-redo?=~a depth=~a\n"
        (buffer-can-undo? b) (buffer-can-redo? b) (buffer-depth b))
(printf "undo ok?=~a -> ~s\n" (buffer-undo! b) (buffer-string b))
(printf "undo ok?=~a -> ~s\n" (buffer-undo! b) (buffer-string b))
(printf "还能 undo?=~a  能 redo?=~a\n" (buffer-can-undo? b) (buffer-can-redo? b))
(printf "redo ok?=~a -> ~s\n" (buffer-redo! b) (buffer-string b))

(title "关掉记步：编辑只推进 current，不动 past")
(buffer-set-history-enabled! b #f)
(view-set-point! v (point 0 0))
(void (buffer-edit! b v (op-type "X")))
(printf "内容: ~s  enabled?=~a can-undo?=~a\n"
        (buffer-string b) (buffer-history-enabled? b) (buffer-can-undo? b))

(title "清历史")
(buffer-clear-history! b)
(printf "清后 can-undo?=~a depth=~a\n" (buffer-can-undo? b) (buffer-depth b))
