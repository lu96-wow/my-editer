#lang racket

;;; editor.rkt —— core 入口
;;;
;;; 宿主直接持有 buffer / view 对象；这里再导出各层 API 与值词汇表。
;;;
;;;   state      buffer / view 对象 + 结构手术
;;;   ops        纯轴算子 + 提交壳
;;;   query      读
;;;   attributes 端口 / 槽写回
;;;   history    纯文档版本栈
;;;   render     display list → screen

(require "editor/state.rkt" "editor/ops.rkt" "editor/query.rkt"
         "editor/attributes.rkt" "editor/render.rkt" "editor/history.rkt"
         ;; 值词汇表（按需直接用低层模块亦可）
         "text/document.rkt"
         "text/base/point.rkt" "text/base/selection.rkt"
         "text/base/range.rkt" "text/base/change.rkt"
         "view/base/screen.rkt" "view/patch.rkt" "view/compose.rkt")

(provide
 (all-from-out "editor/state.rkt")
 (all-from-out "editor/ops.rkt")
 (all-from-out "editor/query.rkt")
 (all-from-out "editor/attributes.rkt")
 (all-from-out "editor/render.rkt")
 (all-from-out "editor/history.rkt")
 (all-from-out "text/document.rkt")
 (all-from-out "text/base/point.rkt")
 (all-from-out "text/base/selection.rkt")
 (all-from-out "text/base/range.rkt")
 (all-from-out "text/base/change.rkt")
 (all-from-out "view/base/screen.rkt")
 (all-from-out "view/patch.rkt")
 (all-from-out "view/compose.rkt"))
