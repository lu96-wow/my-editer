#lang racket
;;; 10 —— 编辑会话：显式合并的交互封装
;;;
;;; 运行：racket temp/10-session.rkt
;;;
;;; core 里合并完全显式（无 tag、无启发式）：
;;;   · buffer-edit! 每次 = 一步；
;;;   · buffer-with-undo-step 把一组合成一步（程序用）。
;;; session 把「连续打字合成一步、移动光标收步」包好给交互宿主：
;;;   · session-edit!   编辑（自动开 / 续步）；
;;;   · session-*!      导航 / 选区 / undo-redo（先收步）；
;;;   · session-break!  手动收步（失焦 / 超时）。

(require "../core/editor.rkt")

(define (title x) (printf "\n==== ~a ====\n" x))

(define b (make-buffer "hello"))
(define v (buffer-add-view! b 40 10))
(define s (make-edit-session b))
(define (show label)
  (printf "~a: doc=~s depth=~a can-undo?=~a\n"
          label (buffer-string b) (buffer-depth b) (buffer-can-undo? b)))

(title "连续打字：自动合并成一步")
(view-set-point! v (point 0 5))
(void (session-edit! s v (op-type "!")))
(show "打 !")
(void (session-edit! s v (op-type "?")))
(show "打 ?（仍一步）")

(title "导航收步：再编辑就是新的一步")
(session-left! s v)
(show "左移（收步）")
(void (session-edit! s v (op-type "X")))
(show "插入 X（第二步）")

(title "session-undo! 自带收步")
(session-undo! s)
(show "undo 一次（撤 X）")
(session-undo! s)
(show "再 undo（撤 !?）")

(title "session-set-point! 也收步")
(define b2 (make-buffer "abc"))
(define v2 (buffer-add-view! b2 40 10))
(define s2 (make-edit-session b2))
(void (session-edit! s2 v2 (op-type "1")))
(session-set-point! s2 v2 (point 0 0))
(void (session-edit! s2 v2 (op-type "2")))
(printf "doc=~s depth=~a（编辑-定位-编辑 = 两步）\n"
        (buffer-string b2) (buffer-depth b2))

(title "session-break!：手动收步（失焦 / 超时）")
(define b3 (make-buffer "x"))
(define v3 (buffer-add-view! b3 40 10))
(define s3 (make-edit-session b3))
(void (session-edit! s3 v3 (op-type "1")))
(session-break! s3)                       ; 例如：失焦
(void (session-edit! s3 v3 (op-type "2")))
(printf "doc=~s depth=~a（break 后 = 两步）\n" (buffer-string b3) (buffer-depth b3))

(title "程序写镜像：默认独立成步")
(define bp (make-buffer "abc\ndef"))
(define vp (buffer-add-view! bp 40 10))
(define sp (make-edit-session bp))
(view-set-point! vp (point 1 3))
(void (session-edit! sp vp (op-type "!")))   ; 打字
(void (session-set-line! sp 0 "ZZZ"))            ; 镜像程序写：先收步再写
(printf "doc=~s depth=~a（打字一步 + 程序写一步）\n" (buffer-string bp) (buffer-depth bp))
(void (buffer-undo! bp))
(printf "undo 一次 -> ~s（只撤程序写）\n" (buffer-string bp))
