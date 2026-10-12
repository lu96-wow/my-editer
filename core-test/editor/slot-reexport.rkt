#lang racket

;;; 开放槽：只用 core/editor.rkt 就能声明 / 使用（不再挖 text/slot-dsl、text/slots）。
;;; 对应 editor.rkt 对 `define-document-slot` + `fork-ctx` 的再导出。

(require rackunit
         "../../core/editor.rkt")

;; 声明槽（transform 里用 fork-ctx，验证 fork-ctx 也在公共面）
(define (count-changes old ctx) (+ old (length (fork-ctx-changes ctx))))
(define-document-slot edits #:default 0 #:fork (transform count-changes))

(define ed (editor-open "abc" 20 5))
(check-equal? (editor-document-slot-ref ed 0 edits) 0)

;; 编辑 → 槽按 fork 计划推进，且能读到本次 changes
(define-values (chg ok) (editor-view-insert! ed 0 "X"))     ; "Xabc"
(check-true ok)
(check-equal? (length chg) 1)
(check-equal? (editor-document-slot-ref ed 0 edits) 1)

;; 直接写回
(editor-document-slot-set! ed 0 edits 99)
(check-equal? (editor-document-slot-ref ed 0 edits) 99)

;; 命名访问器（宏生成）与通用读同源
(check-equal? (document-slot-edits (editor-document-handle ed 0)) 99)

(displayln "slot-reexport.rkt: all tests passed")
