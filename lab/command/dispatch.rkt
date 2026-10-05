#lang racket

(require "table.rkt"
         "registry.rkt"
         "../base/input.rkt")

;;; lab-rebuild/command/dispatch.rkt —— 派发接缝
;;;
;;; 给定「当前是谁」（did）+ 一个事件 + **额外表**（模态），选出该跑哪条命令并执行。
;;; 本文件不认识 core、焦点、模式状态：did 和 extra-tables 都由上层算好传进来。
;;;
;;;   dispatch-tables  cs did extra      → 生效的表（global + did表 + extra）
;;;   dispatch-lookup  cs did extra ev   → 命令描述 / #f
;;;   dispatch-run     cs did extra ev app → 跑，命中返回 #t，否则 #f
;;;
;;; 「输入是另一种转移状态」接在这里：extra = (mode-tables mode ...)。
;;; 于是模态不再是「偷偷改 command-set」，而是 dispatch 的一个显式维度。

(provide dispatch-tables dispatch-lookup dispatch-run dispatch-run-direct)

;; did : document id / #f（没有前台文档）。
(define (dispatch-tables cs did extra-tables)
  (append (command-set-tables cs did) extra-tables))

(define (dispatch-lookup cs did extra-tables event)
  (command-lookup (dispatch-tables cs did extra-tables) (event->binding event)))

(define (dispatch-run cs did extra-tables event app)
  (define spec (dispatch-lookup cs did extra-tables event))
  (and spec (begin (command-invoke spec event app) #t)))

;; 直接给一张表（前缀键只查它自己的表，不按 did / 不回落）。
(define (dispatch-run-direct tables event app)
  (define spec (command-lookup tables (event->binding event)))
  (and spec (begin (command-invoke spec event app) #t)))
