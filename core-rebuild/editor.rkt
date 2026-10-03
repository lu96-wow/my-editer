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
;;; **身份 struct 也不在入口**：`view` / `document-entry` / `history` / `editor` 的字段都是内部件，
;;; 宿主用 `editor-*` 操作与 id 枚举；需要值就取 `editor-document-handle`。
;;;
;;; 低层（document / viewport / screen / edit / …）在各自模块；需要时单独 require。

(require "editor/state.rkt" "editor/command.rkt"
         "editor/query.rkt" "editor/attributes.rkt"
         ;; view-change-text 是操作 → 入口改名；词汇表（change/range）改由下面裸名转发。
         (rename-in "editor/change.rkt"
                    [view-change-text editor-view-change-text])
         "editor/render.rkt" "editor/sync.rkt" "editor/layout.rkt"
         ;; ---------- 值词汇表（宿主要构造 / 消费的值；入口按裸名转发） ----------
         "text/base/point.rkt"
         "text/base/selection.rkt"
         "text/base/range.rkt"
         "text/base/change.rkt"
         "text/document.rkt"
         "view/base/screen.rkt"
         "view/patch.rkt"
         "view/compose.rkt")

(provide
 ;; ---------- 数据 + 结构操作 + 读（身份 struct / 裸 box / 内部查找 不对外） ----------
 (except-out (all-from-out "editor/state.rkt")
   ;; 裸 box setter
   document-entry-set-name! document-entry-set-history!
   view-set-viewport! view-set-selections! view-set-sync! view-set-link!
   editor-set-clipboard! ->document
   ;; editor 骨架的字段（只留 editor?）
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
 ;; ---------- 用户命令（内部原语 step / install! / record! 不对外） ----------
 (except-out (all-from-out "editor/command.rkt")
             step step? step-pre-value step-pre-sels step-post-value step-post-sels
             step-who step-pre-tip
             editor-view-install! editor-document-history-record!)
 ;; ---------- 读 ----------
 (all-from-out "editor/query.rkt")
 ;; ---------- 属性覆盖层（裸原子 / 视图句柄 不对外；值句柄 editor-document-handle 留着） ----------
 (except-out (all-from-out "editor/attributes.rkt")
             editor-view-document-handle editor-view-highlight-atom editor-view-readonly-atom)
 ;; ---------- 变更（编辑命令返回的 change） ----------
 (all-from-out "editor/change.rkt")
 ;; ---------- 渲染 / 投影 ----------
 (all-from-out "editor/render.rkt")
 ;; ---------- 视口同步 ----------
 (all-from-out "editor/sync.rkt")
 ;; ---------- 布局（rects → view 尺寸 + 屏幕） ----------
 (all-from-out "editor/layout.rkt")

 ;; ---------- 值词汇表（裸名：类型 + 构造 / 读 / 建） ----------
 ;; 规则：操作 = editor-*；值词汇 = 裸名（与已有的 rect 一致）。
 (except-out (all-from-out "text/base/point.rkt")
             point-left point-right point-home point-end)   ; 需要 track，宿主拿不到
 (all-from-out "text/base/selection.rkt")
 (all-from-out "text/base/range.rkt")
 (all-from-out "text/base/change.rkt")
 (except-out (all-from-out "text/document.rkt")
   ;; 表示 / 裸 box / 编辑机制：不进入口。文档是**值**（document-open + *-fill-batch 构造），
   ;; 编辑是 editor 的活。
   document document-im document-mut
   document-immutable document-immutable? document-immutable-text
   document-mutable document-mutable? document-mutable-highlight document-mutable-readonly
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
