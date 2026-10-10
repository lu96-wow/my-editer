#lang racket

;;; edit-rebuild/core/session/input-state.rkt —— 输入状态（纯）
;;;
;;; 局部问题：输入焦点 / 活动编辑视图 / 多键前缀 / 输入行。决定「输入此刻指向谁」。
;;; 焦点值本体是 focus.rkt（层 1）；这里只存它在会话里的位置与相关输入态。

(require "../focus.rkt")

(provide (struct-out input-state)
         input-state-new
         input-state-set-focus input-state-set-prefix input-state-set-edit-vid)

(struct input-state (focus edit-vid prefix prompt) #:transparent)
;; focus    : focus（输入焦点 + 还原栈）
;; edit-vid : 活动编辑视图（粘性：焦点落到非面时更新）
;; prefix   : prefix | #f   活动的前缀（多键序列）
;; prompt   : prompt | #f   打开的输入行

(define (input-state-new focus)
  (input-state focus (focus-target focus) #f #f))

(define (input-state-set-focus i focus)
  (struct-copy input-state i [focus focus]))

(define (input-state-set-edit-vid i vid)
  (struct-copy input-state i [edit-vid vid]))

(define (input-state-set-prefix i prefix)
  (struct-copy input-state i [prefix prefix]))
