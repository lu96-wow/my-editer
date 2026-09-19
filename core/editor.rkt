#lang racket

;;; core/editor.rkt —— 使用者标准入口：原子 + editor 平台（多 buffer 多视图）
;;;
;;; 一个 require 拿到编一个多 buffer 编辑器要用的全部：
;;;   · editor-*   ：有状态操作（buffer/view 管理、读、标注、编辑、撤销、投影）
;;;   · 原子        ：point / edit-desc / edit-change / restrict / patch /
;;;                   buffer / window / screen / events / width / window->screen
;;;
;;; 下面的层（document 机制、content/properties/… 内部结构）都不在这里透出；
;;; 全量面（含机制）在 core/api.rkt。

(require "api.rkt"
         "compose/editor.rkt")

(provide
 (all-from-out "compose/editor.rkt")
 (all-from-out "api.rkt"))

(module+ test
  (require rackunit)
  (define ed (editor-open "hi"))
  (define-values (ed* report) (editor-edit ed (edit-insert "!")))
  (check-equal? (editor-buffer->string ed* 0) "!hi")
  (check-equal? (change-report-first-line report) 0)
  (check-true (screen? (editor->screen ed*)))
  (check-true (text-event? (text-event "a" (modifiers #f #f #f #f))))
  (displayln "editor.rkt: all tests passed"))
