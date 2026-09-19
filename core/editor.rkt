#lang racket

;;; core/editor.rkt —— 使用者标准入口
;;;
;;; 一个 require 拿到全平台：
;;;   · 原子          point / edit-desc / buffer / window / screen / events / …
;;;   · editor 状态   editor / 查询 / 解析 / 标注 / 投影          （compose/editor.rkt）
;;;   · 显示语义      none / map / leader                          （compose/reaction.rkt）
;;;   · 程序面        editor-edit-at 等（默认不动视图）            （compose/program.rkt）
;;;   · 用户面        editor-edit / 导航 / 撤销 / 焦点             （compose/command.rkt）
;;;
;;; 全量面（含机制）在 core/api.rkt。

(require "api.rkt"
         "compose/editor.rkt"
         "compose/reaction.rkt"
         "compose/program.rkt"
         "compose/command.rkt")

(provide
 (all-from-out "compose/command.rkt")
 (all-from-out "compose/program.rkt")
 (all-from-out "compose/reaction.rkt")
 (all-from-out "compose/editor.rkt")
 (all-from-out "api.rkt"))

(module+ test
  (require rackunit)
  ;; 用户面
  (define ed (editor-open "hi"))
  (define-values (ed* report) (editor-edit ed (edit-insert "!")))
  (check-equal? (editor-buffer->string ed* 0) "!hi")
  (check-equal? (change-report-first-line report) 0)
  ;; 程序面：默认不动视图
  (define ed2 (editor-open "hi"))
  (define-values (ed2* _r2) (editor-edit-at ed2 0 (point 0 0) (edit-insert "!")))
  (check-equal? (editor-buffer->string ed2* 0) "!hi")
  (check-equal? (editor-point ed2*) (point 0 0))
  ;; 投影 + 原子
  (check-true (screen? (editor->screen ed*)))
  (check-true (text-event? (text-event "a" (modifiers #f #f #f #f))))
  (displayln "editor.rkt: all tests passed"))
