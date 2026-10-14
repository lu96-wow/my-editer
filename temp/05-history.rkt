#lang racket
;;; 05 —— 历史：undo / redo / 记步 / 显式事务
;;;
;;; 运行：racket temp/05-history.rkt
;;;
;;; history = 纯文档版本栈（past / current / future）。没有 who/selections，也没有合并策略。
;;; 合并完全显式：每次 buffer-edit! = 一步；一组操作合成一步用 buffer-with-undo-step。
;;; 交互层的「连续打字合成一步」由 session 提供（见 10）。

(require "../core/editor.rkt")

(define b (make-buffer "one\ntwo"))
(define v (buffer-add-view! b 40 10))

(define (title s) (printf "\n==== ~a ====\n" s))

(title "每次编辑 = 一步（无隐式合并）")
(view-set-point! v (point 0 3))
(void (buffer-edit! b v (op-type "!")))
(void (buffer-edit! b v (op-type "?")))
(printf "内容: ~s  undo 步数: ~a（两下 = 两步）\n" (buffer-string b) (buffer-depth b))

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

(title "undo 事务：一组程序编辑合成一步")
(define b2 (make-buffer "abc"))
(printf "起始 doc=~s depth=~a\n" (buffer-string b2) (buffer-depth b2))
(void (buffer-with-undo-step b2
  (lambda ()
    (buffer-set-char! b2 0 0 #\X)
    (buffer-set-char! b2 0 1 #\Y)
    (buffer-set-char! b2 0 2 #\Z))))
(printf "事务后 doc=~s depth=~a（三次编辑 = 一步）\n" (buffer-string b2) (buffer-depth b2))
(void (buffer-undo! b2))
(printf "undo 一次 -> ~s\n" (buffer-string b2))
