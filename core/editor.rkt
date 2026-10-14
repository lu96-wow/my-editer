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
 ;; 对象：buffer / view 的持有、构造与结构手术
 (all-from-out "editor/state.rkt")      ; buffer / view 对象 + 结构手术
 ;; 算子：编辑算子 + 提交壳（编辑 / 导航 / 视口 / undo-redo）
 (all-from-out "editor/ops.rkt")        ; 纯编辑算子 + 提交壳
 ;; 读：文本 / 名称、端口 / 槽、点 / 选区、坐标换算、视口状态、历史
 (all-from-out "editor/query.rkt")      ; 按对象读
 ;; 写回：face / readonly / 槽（按 buffer）
 (all-from-out "editor/attributes.rkt") ; 端口 / 槽写回
 ;; 渲染：display list → screen（含增量 patch）
 (all-from-out "editor/render.rkt")     ; display list → screen
 ;; 历史：纯文档版本栈
 (all-from-out "editor/history.rkt")    ; 纯文档版本栈
 ;; 值词汇表：文档
 (all-from-out "text/document.rkt")     ; document：文本 + 端口 / 槽
 ;; 值词汇表：点 / 选区 / 区间 / 变更
 (all-from-out "text/base/point.rkt")   ; point（line, column）
 (all-from-out "text/base/selection.rkt") ; selection / selections
 (all-from-out "text/base/range.rkt")   ; range 半开区间
 (all-from-out "text/base/change.rkt")  ; change 变更描述
 ;; 值词汇表：屏幕 / 差量 / 图层合成
 (all-from-out "view/base/screen.rkt")  ; screen / run / cursor / region
 (all-from-out "view/patch.rkt")        ; piece + 屏幕差量
 (all-from-out "view/compose.rkt")      ; pane / composition 图层合成
 ;; 说明：以上均为再导出，各名字的具体用途见对应模块 provide。
 )
