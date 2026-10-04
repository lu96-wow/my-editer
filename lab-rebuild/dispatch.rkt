#lang racket

(require "command.rkt"
         "input.rkt")

;;; lab-rebuild/dispatch.rkt —— 派发接缝（骨架）
;;;
;;; 职责：给定「当前是谁」（did）+ 一个事件，选出该事件该跑哪张表，并调用 handler。
;;; 本文件**不认识** core、焦点、模式状态：did 由上层算好传进来。
;;;
;;;   dispatch-tables  cs did          → 生效的表（global + 该 did）
;;;   dispatch-lookup  cs did event    → handler / #f
;;;   dispatch-run     cs did event ctx→ 跑，命中返回 #t，否则 #f
;;;
;;; handler 调用约定： (handler event ctx)。ctx 由上层给（编辑器、几何、app 状态…），
;;; 本层不解释它。
;;;
;;; ⚠ 这里是「输入是另一种转移状态」的挂载点。
;;;   现在的规则是「did → 表」，即「谁在前台，就用谁的（+全局）表」。
;;;   转移状态（提示 / 确认 / 其它模态）要么：
;;;     (a) 也表达成一个 did（切 view / 切文档），于是天然走这套；或
;;;     (b) 在 did 之外再叠一层「模式表」，dispatch-tables 多收一个 mode 参数。
;;;   两种都行 —— 先留白，等骨架定了单独讨论。当前签名按 (a) 的形态给。

(provide dispatch-tables dispatch-lookup dispatch-run)

;; did : document id / #f（没有前台文档）。
(define (dispatch-tables cs did)
  (command-set-tables cs did))

(define (dispatch-lookup cs did event)
  (command-lookup (dispatch-tables cs did) (event->binding event)))

(define (dispatch-run cs did event ctx)
  (command-run (dispatch-tables cs did) (event->binding event) event ctx))
