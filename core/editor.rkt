#lang racket

;;; editor.rkt —— editor 平台入口
;;;
;;; 结构操作（增/删文档、视图）→ 返回新 editor（editor-add-* / editor-close-*）。
;;; 命令式操作（editor-view-*!）就地改 box、不返回 editor：
;;;     编辑   → (values changes ok?)（changes 空 = 没改动；ok? #f = 被只读挡）
;;;     undo/redo → ok?；CAS → applied?；其余 → void
;;;
;;;   state   数据 + 查找 + 构造 + 结构操作 + 就地写槽（editor/state.rkt）
;;;   history 撤销/重做账本（editor/history.rkt）
;;;   view    单视图维护 / 同文档视图传播（editor/view.rkt）
;;;   command 命令式操作 editor-view-*!（editor/command.rkt）
;;;   query   读：文本 / 点 / 屏幕坐标 / 视口 / 历史（editor/query.rkt）
;;;   attributes 属性覆盖层：高亮 / 只读的写回（editor/attributes.rkt）
;;;   change  读：编辑命令返回的 change（editor/change.rkt）
;;;   render  单视图渲染 + 增量投影（editor/render.rkt）
;;;   layout  rectangle 布局：尺寸落到 view、位置用于贴屏（editor/layout.rkt）
;;;   sync    视口同步（editor/sync.rkt）
;;;
;;; 低层（document / viewport / screen / edit / …）在各自模块；需要时单独 require。

(require "editor/state.rkt" "editor/command.rkt"
         "editor/query.rkt" "editor/attributes.rkt"
         ;; view-change-text 在入口改名为 editor-view-change-text。
         (rename-in "editor/change.rkt"
                    [view-change-text editor-view-change-text])
         "editor/render.rkt" "editor/sync.rkt" "editor/layout.rkt"
         ;; ---------- 值词汇表 ----------
         "text/base/point.rkt"
         "text/base/selection.rkt"
         "text/base/range.rkt"
         "text/base/change.rkt"
         "text/document.rkt"
         "view/base/screen.rkt"
         "view/patch.rkt"
         "view/compose.rkt")

(provide
 ;; ---------- 数据 + 结构操作 + 读 ----------
 (except-out (all-from-out "editor/state.rkt")
   ;; 裸 box setter
   document-entry-set-name! document-entry-set-history!
   view-set-viewport! view-set-selections! view-set-sync! view-set-link!
   editor-set-clipboard! ->document
   ;; editor 骨架字段
   editor editor-documents editor-views editor-next-document editor-next-view editor-clipboard-box
   ;; 身份 struct 与其 accessors
   document-entry document-entry? document-entry-im document-entry-mut
   document-entry-id document-entry-name document-entry-history document-entry-document
   entry-immutable entry-immutable? entry-immutable-id
   entry-mutable entry-mutable? entry-mutable-name entry-mutable-history
   view view? view-im view-mut view-id view-did view-viewport view-selections view-sync view-link
   view-immutable view-immutable? view-immutable-id view-immutable-did
   view-mutable view-mutable? view-mutable-viewport view-mutable-selections view-mutable-sync view-mutable-link
   make-document-entry make-view
   ;; 内部查找 / 解析
   editor-document-entry editor-view-ref editor-view-document editor-document-history
   document-id-of first-view-of-document)
 ;; ---------- 用户命令 ----------
 (except-out (all-from-out "editor/command.rkt")
             step step? step-pre-value step-pre-sels step-post-value step-post-sels
             step-who step-pre-tip
             editor-view-install! editor-document-history-record!)
 ;; ---------- 读 ----------
 (all-from-out "editor/query.rkt")
 ;; ---------- 属性覆盖层 ----------
 (except-out (all-from-out "editor/attributes.rkt")
             editor-view-document-handle editor-view-highlight-atom editor-view-readonly-atom)
 ;; ---------- 变更（编辑命令返回的 change） ----------
 (all-from-out "editor/change.rkt")
 ;; ---------- 渲染 / 投影 ----------
 (all-from-out "editor/render.rkt")
 ;; ---------- 视口同步 ----------
 (all-from-out "editor/sync.rkt")
 ;; ---------- 布局（rectangles → view 尺寸 + 屏幕） ----------
 (all-from-out "editor/layout.rkt")

 ;; ---------- 值词汇表（类型 + 构造 / 读 / 建） ----------
 (except-out (all-from-out "text/base/point.rkt")
             point-left point-right point-home point-end)
 (all-from-out "text/base/selection.rkt")
 (all-from-out "text/base/range.rkt")
 (all-from-out "text/base/change.rkt")
 (except-out (all-from-out "text/document.rkt")
   ;; 表示 / 裸 box / 编辑机制
   document document-im document-mut
   document-immutable document-immutable? document-immutable-text
   document-mutable document-mutable? document-mutable-highlight document-mutable-readonly
   ;; 属性轨
   document-highlight document-readonly
   document-set-highlight! document-set-readonly! document-highlight-atom document-readonly-atom
   document-edit-tracks document-edit-highlight document-edit-readonly
   document-insert document-insert-ignore-readonly
   document-delete document-delete-ignore-readonly
   document-replace document-replace-ignore-readonly
   document-paste document-paste-ignore-readonly
   document-aligned? document-text)
 (all-from-out "view/base/screen.rkt")
 (all-from-out "view/patch.rkt")
 (all-from-out "view/compose.rkt"))
