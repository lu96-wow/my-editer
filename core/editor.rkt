#lang racket

;;; editor.rkt —— editor 平台入口
;;;
;;; **API 约定（可变）**：
;;;     结构操作（增/删文档、视图）→ 返回新 editor（editor-add-* / editor-close-*）
;;;     命令式操作（editor-view-*!）→ 就地改 box、**不返回 editor**：
;;;         编辑   → (values changes ok?)
;;;         undo/redo → ok?；CAS → applied?；其余 → void
;;;     box 引用一经创建不再替换，只 set-box! 内容（身份不可变，其余全在 box）。
;;;
;;;   state   数据 + 查找 + 构造 + 结构操作 + 就地写槽（core/editor/state.rkt）
;;;   history 撤销/重做账本（core/editor/history.rkt）
;;;   view    单视图维护 / 同文档视图传播（core/editor/view.rkt，内部用）
;;;   command 命令式操作 editor-view-*!（core/editor/command.rkt）
;;;   query   读：文本 / 点 / 屏幕坐标 / 视口 / 历史（core/editor/query.rkt）
;;;   attributes 属性覆盖层：高亮 / 只读的句柄式写回，O(1)（core/editor/attributes.rkt）
;;;   change  读：编辑命令返回的 change（core/editor/change.rkt）
;;;   render  单视图渲染 + 增量投影（core/editor/render.rkt）
;;;   layout  rect 布局：尺寸落到 view、位置用于贴屏（core/editor/layout.rkt）
;;;   sync    视口同步（core/editor/sync.rkt）
;;;
;;; **editor 不持焦点**：哪个 view 当前被操作由宿主决定，接口一律显式 vid/did。
;;;
;;; **裸 box setter**（document-entry-set-history! / view-set-selections! …）不在入口：
;;; 它们绕过 clamp / 账本不变量，只给 command / view / sync 内部用。
;;; 公开面是命令式 editor-view-*! 与结构操作 editor-add/close-*。
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
 ;; ---------- 数据 + 结构操作 + 读（排除裸 box setter：只内部用） ----------
 (except-out (all-from-out "editor/state.rkt")
             document-entry-set-name! document-entry-set-history!
             view-set-viewport! view-set-selections! view-set-sync! view-set-link!
             editor-set-clipboard! ->document)
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
