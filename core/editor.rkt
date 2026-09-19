#lang racket

;;; core/editor.rkt —— 使用者总入口：原子 + editor 平台
;;;
;;; 一个 require 拿到编一个编辑器要用的全部：
;;;   · editor-*   ：有状态操作（读 / 标注 / 编辑 / 撤销 / 视图）—— 平时只碰这些
;;;   · 原子        ：point / edit-desc / edit-change / restrict / patch /
;;;                   buffer / window / screen / events / width / window->screen
;;;
;;; **document-* 不从这里透出**：它是 editor 内部的机制（buffer + 多视图 + rebase）。
;;; 真要下探时：`(editor-document ed)` 拿到 document，再去 `core/api.rkt` 用 document-*。
;;;
;;; 所以使用者看到的是一套统一前缀：状态操作全是 editor-*。

(require "api.rkt"
         "compose/editor.rkt")

(provide
 ;; editor 平台（有状态操作）
 (all-from-out "compose/editor.rkt")
 ;; 原子（无状态的「东西」与它们的原语）
 (except-out (all-from-out "api.rkt")
             ;; —— document 机制，不透出 ——
             document document? struct:document
             document-open document-of-buffer
             document->string document->lines document-line-count document-line-ref
             document-get-property document-read-only-at? document-restrict-runs
             document-range-text
             document-add-view document-view-count document-window
             document-view-sync document-set-view-sync document-update-view
             document-set-view-size document-sync-followers
             document-update-buffer document-put-property document-remove-property
             document-put-properties-many document-put-restrict document-apply-patches
             document-edit document-apply-descs-trusted document-buffer))

(module+ test
  (require rackunit)
  ;; 平台可用
  (define ed (editor-open "hi"))
  (check-equal? (editor->string ed) "hi")
  (define-values (ed* report) (editor-edit ed (edit-insert "!")))
  (check-equal? (editor->string ed*) "!hi")
  (check-equal? (change-report-first-line report) 0)
  ;; 原子可用（渲染/输入）
  (check-equal? (screen-rows (window->screen (editor-window ed*))) 24)
  (check-true (text-event? (text-event "a" (modifiers #f #f #f #f))))
  (displayln "editor.rkt: all tests passed"))
