#lang racket

;;; editor/session.rkt —— 编辑会话（显式合并的交互封装）
;;;
;;; 在 ops 的「显式合并」之上，给交互宿主一个开箱即用的层：
;;;
;;;   一次「连续编辑」= 一个事务（一个 undo 步）。
;;;   · session-edit!   编辑：无开步则开，续步；
;;;   · session-*!      导航 / 选区 / 程序写 / undo-redo：**先收步再执行**（镜像 API，不会忘）；
;;;   · session-break!  手动收步（失焦 / 超时）。
;;;
;;; 于是宿主不必自己记「当前步是否开着」——只要编辑走 session-edit!、
;;; 打断动作走 session-*!，合并边界就自动正确。

(require "state.rkt" "ops.rkt")

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
 session-nav!
 session-left! session-right! session-up! session-down! session-home! session-end!

 ;; ---------- 选区 / 定位镜像（先收步） ----------
 session-set-selections! session-set-point! session-select-all!
 session-add-selection! session-remove-selection!

 ;; ---------- 程序写镜像（先收步 → 独立成步） ----------
 session-replace!                 ; session value [#:ensure? #:changes]
 session-replace-range!           ; session range text [#:ensure?]
 session-set-line!                ; session line text
 session-set-char!                ; session line col char
 session-commit-if-unchanged!     ; session base-doc new-doc → applied?

 ;; ---------- 历史 / 生命周期镜像（先收步） ----------
 session-reset-history!           ; session [enabled? #t] → void
 session-set-history-enabled!     ; session flag → void
 session-close-view!              ; session view → void
 session-close!)                  ; session → void

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

;;; ---------- 程序写镜像（先收步 → 独立成步） ----------
;;; 程序写默认独立成一个 undo 步，不并进当前打字步。
;;; 若想让它并入当前步，直接用裸 buffer-* 版本（不 break）。

(define (session-replace! s value #:ensure? [ensure? #f] #:changes [changes #f])
  (session-break! s)
  (buffer-replace! (edit-session-buffer s) value #:ensure? ensure? #:changes changes))

(define (session-replace-range! s r text #:ensure? [ensure? #f])
  (session-break! s)
  (buffer-replace-range! (edit-session-buffer s) r text #:ensure? ensure?))

(define (session-set-line! s line text)
  (session-break! s)
  (buffer-set-line! (edit-session-buffer s) line text))

(define (session-set-char! s line col ch)
  (session-break! s)
  (buffer-set-char! (edit-session-buffer s) line col ch))

(define (session-commit-if-unchanged! s base-doc new-doc)
  (session-break! s)
  (buffer-apply-if-version! (edit-session-buffer s) base-doc new-doc))

;;; ---------- 历史 / 生命周期镜像（先收步） ----------

(define (session-reset-history! s [enabled? #t])
  (session-break! s)
  (buffer-reset-history! (edit-session-buffer s) enabled?))

(define (session-set-history-enabled! s flag)
  (session-break! s)
  (buffer-set-history-enabled! (edit-session-buffer s) flag))

(define (session-close-view! s v)
  (session-break! s)
  (buffer-close-view! (edit-session-buffer s) v))

(define (session-close! s)
  (session-break! s)
  (buffer-close! (edit-session-buffer s)))

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
