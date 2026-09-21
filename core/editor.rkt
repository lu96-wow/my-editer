#lang racket

;;; core/editor.rkt —— 使用者标准入口
;;;
;;; 一个 require 拿到：
;;;   · 低层公开面  point / edit-desc / buffer / window / screen / events / …   （api.rkt）
;;;   · editor 中性面  构造 / 查询 / 解析 / 属性读 / 投影   （platform/neutral.rkt）
;;;   · 程序面        editor-edit-at / 显式视图命令 / 属性写   （platform/program.rkt）
;;;   · 用户面        editor-edit / 导航 / 撤销 / 焦点        （platform/command.rkt）
;;;
;;; 内部机制不在这里：platform/state.rkt（数据/查找）、platform/write.rkt（写原语）、
;;; platform/reaction.rkt（显示语义）。低层公开面在 core/api.rkt。

(require "api.rkt"
         "platform/neutral.rkt"
         "platform/program.rkt"
         "platform/command.rkt")

(provide
 (all-from-out "platform/command.rkt")
 (all-from-out "platform/program.rkt")
 (all-from-out "platform/neutral.rkt")
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
