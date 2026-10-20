#lang racket

;;; edit-tui-rebuild/base/api.rkt —— 骨架的基础值词汇
;;;
;;; 把 core 里插件会用到的纯值再导出，插件因此不需要直接 require core：
;;;   rect                      布局几何
;;;   point / range / caret / selection / selections   文本坐标 / 选区
;;;   char/string-display-width、index<->display-column 宽字符显示列
;;;
;;; 只做「值 + 纯函数」；buffer / view 的操作在 engine/api。

(require "../../core/editor.rkt"
         "../../core/text/base/width.rkt")

(provide (struct-out rect)
         rect-right rect-bottom
         rect-inset rect-inset-sides rect-contains?

         ;; 文本坐标 / 选区
         point point? point-line point-column
         point<? point=? point<=?
         range range? range-of range-start range-end
         range-normalize range-empty?
         caret caret?
         selection selection? selection-point selection-range
         selection-empty? selection-anchor selection-head
         selection-go selection-extend selection-normalize
         selections selections? selections-one selections-items
         selections-count selections-primary selections-primary-index
         selections-add selections-remove selections-set-primary
         selections-go selections-extend selections-normalize
         selections-dedupe selections-clamp

         ;; 显示列（宽字符）
         char-display-width string-display-width
         index->display-column display-column->index)
