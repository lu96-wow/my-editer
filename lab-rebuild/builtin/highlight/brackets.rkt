#lang racket

(require "bracket-pair.rkt"
         "file-kind.rkt"
         "api.rkt")

;;; lab-rebuild/builtin/highlight/brackets.rkt —— 括号按深度背景高亮（内置插件）
;;;
;;; open 走整篇扫描；change 走 base/brackets.rkt 的增量（只用编辑位置重建被破坏的一段）。
;;; 产出 face = (palette-color 'bracket level)，颜色由主题决定。
;;; Racket 文件额外按词法跳过字符串 / 行注释 / 块注释 / 字符字面量里的括号
;;; （见 bracket-pair.rkt），其它文件仍按裸括号配对。

(provide bracket-plugin)

(define (br-open text path)
  (bracket-open text path))

(define (br-change state edits lines path)
  (cond
    [(null? edits) (values state (bstate-fills state))]
    [(null? (cdr edits)) (bracket-change state (car edits) lines path)]
    [else (bracket-open* lines path)]))          ; 一批多个编辑 → 整篇（罕见）

(define bracket-plugin
  (plugin 'brackets racket-applies? br-open br-change))
