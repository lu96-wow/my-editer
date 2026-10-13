#lang racket

;;; edit/core/session/overlay.rkt —— 浮层焦点栈（纯）
;;;
;;; 会话里只有一处「当前接键的浮层」事实，存两个派生自同一栈的值：
;;;
;;;   modes 'overlay        当前接键的浮层 id（#f = 无）—— 供 scope-mode= 判定
;;;   modes 'overlay-stack  打开着的浮层 id 列表，**栈头 = 接键 / 抬到最上**
;;;
;;;   open    打开浮层，追加到栈尾（栈空则自动成为栈头）—— 不抢已有焦点；
;;;   focus!  把浮层移到栈头（Tab 切换 / 鼠标点击）；
;;;   close   从栈里移除（焦点自然落回下一个）；
;;;   cycle   栈头移到栈尾（Tab）。
;;;
;;; 这样补全关闭后「谁接键」不需要再问“文档开没开”——栈里下一个就是答案；
;;; 「谁在上层」= 是否在栈头，z 序由 overlay-deep 派生。于是「谁接键」和
;;; 「谁在上」是同一个事实，不会再分叉。

(require "session.rkt")

(provide session-overlay-focus session-overlay-open session-overlay-focus!
         session-overlay-close session-overlay-cycle
         overlay-top-deep overlay-deep)

(define overlay-top-deep 3000)

(define (stack s) (session-mode s 'overlay-stack '()))

;; 写回：栈 + 由栈头派生的『当前接键浮层』。
(define (put s st)
  (session-set-mode (session-set-mode s 'overlay-stack st)
                    'overlay (and (pair? st) (car st))))

;; 当前接键的浮层（= 栈头）；没有 → #f。
(define (session-overlay-focus s) (session-mode s 'overlay #f))

;; 打开浮层：已存在则不动，否则追加到栈尾（不抢已有焦点）。
(define (session-overlay-open s id)
  (define st (stack s))
  (if (memq id st) s (put s (append st (list id)))))

;; 聚焦浮层：移到栈头。
(define (session-overlay-focus! s id)
  (put s (cons id (remove id (stack s)))))

;; 关闭浮层：从栈里移除。
(define (session-overlay-close s id)
  (put s (remove id (stack s))))

;; Tab：栈头移到栈尾（在打开着的浮层间轮换）。
(define (session-overlay-cycle s)
  (define st (stack s))
  (put s (if (or (null? st) (null? (cdr st))) st (append (cdr st) (list (car st))))))

;; 浮层的 z 序：在栈头就抬到最上，否则用基点。
(define (overlay-deep s id base)
  (if (eq? (session-overlay-focus s) id) overlay-top-deep base))
