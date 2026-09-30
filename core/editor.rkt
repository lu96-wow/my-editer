#lang racket

;;; editor.rkt —— editor 平台入口
;;;
;;;   state   数据 + 查找 + 构造 + 生命周期 + 安全写口（core/editor/state.rkt）
;;;   history 撤销/重做账本（core/editor/history.rkt）
;;;   view    单视图维护 / 同文档视图传播（core/editor/view.rkt，内部用）
;;;   command 用户命令（core/editor/command.rkt）
;;;   query   读：文本 / 点 / 屏幕坐标 / 视口 / 历史（core/editor/query.rkt）
;;;   attributes 属性覆盖层：高亮 / 只读的句柄式写回，O(1)（core/editor/attributes.rkt）
;;;   change  读：编辑命令返回的 change（core/editor/change.rkt）
;;;   render  单视图渲染 + 增量投影（core/editor/render.rkt）
;;;   layout  rect 布局：尺寸落到 view、位置用于贴屏（core/editor/layout.rkt）
;;;   sync    视口同步（core/editor/sync.rkt）
;;;
;;; **editor 不持焦点**：哪个 view 当前被操作由宿主决定，接口一律显式 vid/did。
;;;
;;; **不导出**能破坏结构一致的低层写口（core/editor/write.rkt：editor-set-view /
;;; -history）；它们只给 command / sync / view 内部用。
;;;
;;; 低层（document / viewport / screen / edit / …）在各自模块；需要时单独 require。

(require "editor/state.rkt" "editor/history.rkt" "editor/command.rkt"
         "editor/query.rkt" "editor/attributes.rkt"
         ;; change 词汇表：入口统一改为 editor-* 名。
         (rename-in "editor/change.rkt"
                    [change editor-change]
                    [change? editor-change?]
                    [change-before editor-change-before]
                    [change-after editor-change-after]
                    [range editor-range]
                    [range? editor-range?]
                    [range-start editor-range-start]
                    [range-end editor-range-end]
                    [change-post-range editor-change-post-range]
                    [change-map-point editor-change-map-point]
                    [changes-map-point editor-changes-map-point]
                    [changes-map-point-literal editor-changes-map-point-literal]
                    [change-empty? editor-change-empty?]
                    [change-kind editor-change-kind]
                    [view-change-text editor-view-change-text])
         "editor/render.rkt" "editor/sync.rkt" "editor/layout.rkt")

(provide
 ;; ---------- 数据 + 生命周期 + 安全写口 ----------
 (all-from-out "editor/state.rkt")
 ;; ---------- 撤销 / 重做 ----------
 (all-from-out "editor/history.rkt")
 ;; ---------- 用户命令 ----------
 (all-from-out "editor/command.rkt")
 ;; ---------- 读 ----------
 (all-from-out "editor/query.rkt")
 ;; ---------- 属性覆盖层（句柄式写回，O(1)） ----------
 (all-from-out "editor/attributes.rkt")
 ;; ---------- 变更（编辑命令返回的 change） ----------
 (all-from-out "editor/change.rkt")
 ;; ---------- 渲染 / 投影 ----------
 (all-from-out "editor/render.rkt")
 ;; ---------- 视口同步 ----------
 (all-from-out "editor/sync.rkt")
 ;; ---------- 布局（rects → view 尺寸 + 屏幕） ----------
 (all-from-out "editor/layout.rkt"))
