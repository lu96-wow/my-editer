#lang racket

;;; core/editor.rkt —— 编辑器 平台入口（中性面 + 程序面 + 用户面）
;;;
;;;   · 编辑器 中性面  构造 / 查询 / 解析 / 属性读 / 投影   （platform/neutral.rkt）
;;;   · 程序面        编辑器-文档-编辑-在 / 显式视图命令 / 属性写   （platform/program.rkt）
;;;   · 用户面        编辑器-编辑 / 导航 / 撤销 / 焦点        （platform/command.rkt）
;;;
;;; 低层公开面（位置 / 编辑-描述 / 缓冲 / 窗口 / 屏幕 / 事件集 / …）在 core/api.rkt，
;;; 需要时单独 `(require "core/api.rkt")` —— 本入口**不**重新导出它。
;;;
;;; 内部机制不在这里：platform/state.rkt（数据/查找）、platform/write.rkt（写原语）、
;;; platform/reaction.rkt（显示语义）。

(require "platform/neutral.rkt"
         "platform/program.rkt"
         "platform/command.rkt")

(provide
 (all-from-out "platform/command.rkt")
 (all-from-out "platform/program.rkt")
 (all-from-out "platform/neutral.rkt"))

(module+ test
  (require rackunit "api.rkt")
  ;; 用户面
  (define ed (编辑器-打开 "hi"))
  (define-values (ed* 报告) (编辑器-编辑 ed (编辑-插入 "!")))
  (check-equal? (编辑器-文档->字符串 ed* 0) "!hi")
  (check-equal? (变更-报告-首-行 报告) 0)
  ;; 程序面：默认不动视图
  (define ed2 (编辑器-打开 "hi"))
  (define-values (ed2* _r2) (编辑器-文档-编辑-在 ed2 0 (位置 0 0) (编辑-插入 "!")))
  (check-equal? (编辑器-文档->字符串 ed2* 0) "!hi")
  (check-equal? (编辑器-位置 ed2*) (位置 0 0))
  ;; 投影 + 原子（原子来自 core/api.rkt）
  (check-true (屏幕? (编辑器->屏幕 ed*)))
  (check-true (文本事件? (文本事件 "a" (修饰键 #f #f #f #f))))
  (displayln "editor.rkt: all tests passed"))
