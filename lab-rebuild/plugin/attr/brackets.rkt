#lang racket

(require "../../base/brackets.rkt"
         "api.rkt")

;;; lab-rebuild/plugin/brackets.rkt —— 括号按深度背景高亮（内置插件）
;;;
;;; open 走整篇扫描；change 走 base/brackets.rkt 的增量（只用编辑位置重建被破坏的一段）。
;;; 产出 face = (palette-color 'bracket level)，颜色由主题决定。

(provide bracket-plugin)

(define (br-open text path)
  (bracket-open text path))

(define (br-change state edits lines path)
  (cond
    [(null? edits) (values state (bstate-fills state))]
    [(null? (cdr edits)) (bracket-change state (car edits) lines path)]
    [else (bracket-open* lines path)]))          ; 一批多个编辑 → 整篇（罕见）

(define bracket-plugin
  (plugin 'brackets br-open br-change))
