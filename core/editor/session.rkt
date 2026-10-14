#lang racket

;;; editor/session.rkt —— 编辑会话（显式合并的交互封装）
;;;
;;; 在 ops 的「显式合并」之上，给交互宿主一个开箱即用的层：
;;;
;;;   一次「连续编辑」= 一个事务（一个 undo 步）。
;;;   · session-edit!   编辑：无开步则开，续步；
;;;   · session-*!      导航 / 选区 / undo-redo：**先收步再执行**（镜像 API，不会忘）；
;;;   · session-break!  手动收步（失焦 / 超时）。
;;;
;;; 于是宿主不必自己记「当前步是否开着」——只要编辑走 session-edit!、
;;; 打断动作走 session-*!，合并边界就自动正确。

(require "ops.rkt")

(provide
 (struct-out edit-session)        ; buffer / open?
 make-edit-session                ; buffer → session

 ;; ---------- 编辑 ----------
 session-edit!                    ; session view op → #f | (listof change)

 ;; ---------- 手动收步 / 历史 ----------
 session-break!                   ; session → void
 session-undo! session-redo!      ; session → ok?
 session-clear-history!           ; session → void

 ;; ---------- 导航镜像（先收步） ----------
 session-nav! session-char-nav! session-visual-nav!
 session-left! session-right! session-up! session-down! session-home! session-end!

 ;; ---------- 选区 / 定位镜像（先收步） ----------
 session-set-selections! session-set-point! session-select-all!
 session-add-selection! session-remove-selection!)

(struct edit-session (buffer open?) #:mutable)

(define (make-edit-session b) (edit-session b #f))

;; 收步：把本次开启的事务合成一步（无变更则不记）。
(define (session-break! s)
  (when (edit-session-open? s)
    (buffer-end-undo-step! (edit-session-buffer s))
    (set-edit-session-open?! s #f)))

;; 编辑：开步或续步。
(define (session-edit! s v op)
  (unless (edit-session-open? s)
    (buffer-begin-undo-step! (edit-session-buffer s))
    (set-edit-session-open?! s #t))
  (buffer-edit! (edit-session-buffer s) v op))

;;; ---------- 导航镜像 ----------

(define (session-nav! s v f [extend? #f] #:ensure? [ensure? #t])
  (session-break! s)
  (view-nav! v f extend? #:ensure? ensure?))

(define (session-char-nav! s v which extend?)
  (session-break! s)
  (view-char-nav! v which extend?))

(define (session-visual-nav! s v up? extend?)
  (session-break! s)
  (view-visual-nav! v up? extend?))

(define (session-left! s v [extend? #f])  (session-char-nav! s v 'left extend?))
(define (session-right! s v [extend? #f]) (session-char-nav! s v 'right extend?))
(define (session-home! s v [extend? #f])  (session-char-nav! s v 'home extend?))
(define (session-end! s v [extend? #f])   (session-char-nav! s v 'end extend?))
(define (session-up! s v [extend? #f])    (session-visual-nav! s v #t extend?))
(define (session-down! s v [extend? #f])  (session-visual-nav! s v #f extend?))

;;; ---------- 选区 / 定位镜像 ----------

(define (session-set-selections! s v sels #:ensure? [ensure? #t])
  (session-break! s)
  (view-set-selections! v sels #:ensure? ensure?))

(define (session-set-point! s v p)
  (session-break! s)
  (view-set-point! v p))

(define (session-select-all! s v)
  (session-break! s)
  (view-select-all! v))

(define (session-add-selection! s v sel #:ensure? [ensure? #t])
  (session-break! s)
  (view-add-selection! v sel #:ensure? ensure?))

(define (session-remove-selection! s v sel #:ensure? [ensure? #t])
  (session-break! s)
  (view-remove-selection! v sel #:ensure? ensure?))

;;; ---------- 历史 ----------

(define (session-undo! s)
  (session-break! s)
  (buffer-undo! (edit-session-buffer s)))

(define (session-redo! s)
  (session-break! s)
  (buffer-redo! (edit-session-buffer s)))

(define (session-clear-history! s)
  (session-break! s)
  (buffer-clear-history! (edit-session-buffer s)))
