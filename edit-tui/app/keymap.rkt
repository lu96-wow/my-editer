#lang racket

;;; edit-tui-rebuild/app/keymap.rkt —— 配置好的键位集合（纯值）
;;;
;;; keymap 是「一组已经选好的命令表 / stack」，由 config 构造、app-state 持有：
;;;
;;;   overlays         command-table-stack  全局表（顶层在前）
;;;   input-stack      command-table-stack  输入栏独占栈
;;;   placement-table  command-table | #f   放置交互临时表
;;;
;;; 这里只定义形状和查询，不含任何具体键位或命令。

(require "../core/skeleton.rkt")

(provide (struct-out keymap)
         empty-keymap)

(struct keymap
  (overlays
   input-stack
   placement-table)
  #:transparent)

(define empty-keymap
  (keymap command-table-stack-empty
          command-table-stack-empty
          #f))
