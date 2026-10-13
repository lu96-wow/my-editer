#lang racket

;;; edit-rebuild/core/session/input-state.rkt —— 输入状态（纯）
;;;
;;; 局部问题：输入焦点 / 活动编辑视图 / 多键前缀 / 输入行 / 交互模式。
;;; 决定「输入此刻指向谁」。焦点值本体是 focus.rkt（层 1）；这里只存它在会话里的
;;; 位置与相关输入态。
;;;
;;; modes：交互模式的**纯值**（hash 名字 -> 值）。取代散落的可变 box（如原来
;;; completion 的 active），使 scope 能直接声明「谁接键」。

(require "../focus.rkt")

(provide (struct-out input-state)
         input-state-new
         input-state-set-focus input-state-set-prefix input-state-set-edit-vid
         input-state-set-mode)

(struct input-state (focus edit-vid prefix prompt modes) #:transparent)
;; focus    : focus（输入焦点 + 还原栈）
;; edit-vid : 活动编辑视图（粘性：焦点落到非面时更新）
;; prefix   : prefix | #f   活动的前缀（多键序列）
;; prompt   : prompt | #f   打开的输入行
;; modes    : (hash symbol -> any/c)  交互模式（纯值）

(define (input-state-new focus)
  (input-state focus (focus-target focus) #f #f (hash)))

(define (input-state-set-focus i focus)
  (struct-copy input-state i [focus focus]))

(define (input-state-set-edit-vid i vid)
  (struct-copy input-state i [edit-vid vid]))

(define (input-state-set-prefix i prefix)
  (struct-copy input-state i [prefix prefix]))

(define (input-state-set-mode i name val)
  (struct-copy input-state i [modes (hash-set (input-state-modes i) name val)]))
