#lang racket

(require "command.rkt"
         "input.rkt")

;;; lab/base/dispatch.rkt —— 派发接缝
;;;
;;; 给定「当前是谁」（did）+ 一个事件 + **额外表**（模态），选出该跑哪张表并调用 handler。
;;; 本文件**不认识** core、焦点、模式状态：did 和 extra-tables 都由上层算好传进来。
;;;
;;;   dispatch-tables  cs did extra      → 生效的表（global + did表 + extra）
;;;   dispatch-lookup  cs did extra ev   → handler / #f
;;;   dispatch-run     cs did extra ev ctx → 跑，命中返回 #t，否则 #f
;;;
;;; handler 调用约定： (handler event ctx)。ctx 由上层给，本层不解释它。
;;;
;;; 「输入是另一种转移状态」现在**接在这里**：extra = (mode-tables mode ...)。
;;; 于是模态不再是「偷偷改 command-set」，而是 dispatch 的一个显式维度。

(provide dispatch-tables dispatch-lookup dispatch-run)

;; did : document id / #f（没有前台文档）。
(define (dispatch-tables cs did extra-tables)
  (append (command-set-tables cs did) extra-tables))

(define (dispatch-lookup cs did extra-tables event)
  (command-lookup (dispatch-tables cs did extra-tables) (event->binding event)))

(define (dispatch-run cs did extra-tables event ctx)
  (command-run (dispatch-tables cs did extra-tables) (event->binding event) event ctx))
