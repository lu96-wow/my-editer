#lang racket

;;; core/editor.rkt —— 使用者标准入口
;;;
;;; 一个 require 拿到：
;;;   · 原子          point / edit-desc / buffer / window / screen / events / …
;;;   · editor 中性面  构造 / 查询 / 解析 / 标注读 / 投影            （compose/editor.rkt）
;;;   · 程序面        editor-edit-at / 显式视图命令 / 标注写          （compose/program.rkt）
;;;   · 用户面        editor-edit / 导航 / 撤销 / 焦点               （compose/command.rkt）
;;;
;;; 内部机制不在这里：compose/mechanism.rkt（写原语）、compose/reaction.rkt（显示语义）。
;;; 全量原子面在 core/api.rkt。

(require "api.rkt"
         "compose/editor.rkt"
         "compose/program.rkt"
         "compose/command.rkt")

(provide
 (all-from-out "compose/command.rkt")
 (all-from-out "compose/program.rkt")
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
