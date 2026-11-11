#lang racket

;;; edit-tui-rebuild/editor/api.rkt —— 插件唯一能 require 的 editor 面
;;;
;;; 只导出：
;;;   · 操作面（surface）：insert! / delete! / move! / ...
;;;   · 扩展点构造器：make-hook / plugin
;;;   · 只读 State 查询 + UI view 写回
;;;   · core 的值词汇（point / range / selection / change / rect / face）
;;;
;;; 不导出：
;;;   · engine 的创建 / 删除
;;;   · engine 的原始 action 解释入口
;;;   · raw 操作（只有 editor/ops 内部能用）
;;;   · plugin-state 写入口（由 plugin runtime 按 owner 写回）
;;;   · resource 变更入口（由 host 的 open / save / close 写回）
;;;   · host / runtime / IO

(require "../core/api.rkt"
         "../core/job/api.rkt"
         "engine/api.rkt"
         "state.rkt"
         "resource.rkt"
         "mode.rkt"
         "context.rkt"
         "hooks.rkt"
         "plugin.rkt"
         "action.rkt"
         "ops/surface.rkt"
         "layout.rkt"
         "job.rkt"
         "timer.rkt"
         "overlay.rkt")

(provide
 ;; job / service 纯值
 (all-from-out "../core/job/api.rkt")

 ;; core 值词汇：插件只拿构造器 / 查询 / 纯变换，不拿 buffer 编辑壳。
 point point? point-line point-column
 range range? range-start range-end range-normalize range-empty?
 caret caret? selection selection? selection-point selection-range selection-empty?
 selection-anchor selection-head selection-go selection-extend
 selections selections? selections-one selections-of selections-primary selections-primary-index
 change change? change-before change-after change-kind
 rect rect? rect-x rect-y rect-w rect-h rect-right rect-bottom
 rect-inset rect-inset-sides rect-contains?
 panel panel? make-panel empty-panel panel-empty? borders-all borders-none
 buffer? view?

 ;; State 只读查询：插件拿不到 constructor / plugin-states / 写入口。
 ;; helper 同时接受 app-state（host / contribution 回调）和 editor-core。
 editor-state-with-flash
 editor-state-with-layout
 editor-state-with-pending
 editor-state-with-input
 editor-state-with-placement
 editor-state-resource-for-view
 editor-state-resource-for-doc
 editor-state-doc-mode
 editor-state-opened-paths
 editor-state-resources
 editor-state-layout
 editor-state-layout-config
 editor-state-area
 editor-state-input
 editor-state-placement
 editor-state-async?

 ;; resource 只读查询：变更入口只在 host-api。
 resource? resource-id resource-doc-id resource-path resource-name
 resource-views resource-mode resource-saved-version
 resources? resources-list resources-find-path
 resources-find-doc resources-find-view resources-opened-paths
 resource-dirty? resource-normalize-path

 (all-from-out "mode.rkt")
 (all-from-out "context.rkt")
 (all-from-out "hooks.rkt")
 (all-from-out "action.rkt")

 ;; 插件构造面：不导出 host 编排函数
 plugin? make-plugin
 guarded-command? make-guarded-command

 ;; 只读查询
 engine-view-object
 engine-view-text
 engine-doc-text
 engine-doc-version
 engine-view-doc-id
 engine-doc-ids
 engine-view-ids-for-doc
 engine-view-point-line
 engine-view-point-column
 engine-view-cursor-screen-position
 engine-view-face-at

 ;; UI view 写回（status / docs / completion 等普通 view）
 engine-set-view-content!
 engine-set-view-cursor!
 engine-set-view-face-track!
 engine-set-view-face-lines!
 engine-set-view-lines!

 ;; 操作面
 editor-insert!
 editor-delete!
 editor-paste!
 editor-move!
 editor-set-point!
 editor-select!
 editor-scroll!
 editor-undo!
 editor-redo!
 editor-kill-line!
 editor-ensure!

 ;; layout 操作面 + 查询 + 扩展点
 (all-from-out "layout.rkt")

 ;; async job：插件只提交 job、读结果；账本写回只在 host runtime。
 job-result-event? job-result-event-id job-result-event-kind
 job-result-event-result job-result-event-tag
 editor-state-submit-job

 ;; timer
 (all-from-out "timer.rkt")
 (all-from-out "overlay.rkt"))

;;; ════════════════ 操作面包装 ════════════════

(define (editor-insert! ed state vid text)
  (surface-insert! ed state vid text))

(define (editor-delete! ed state vid kind)
  (surface-delete! ed state vid kind))

(define (editor-paste! ed state vid bytes)
  (surface-paste! ed state vid bytes))

(define (editor-move! ed state vid dir [extend? #f])
  (surface-move! ed state vid dir extend?))

(define (editor-set-point! ed state vid line col [extend? #f])
  (surface-set-point! ed state vid line col extend?))

(define (editor-select! ed state vid sels)
  (surface-select! ed state vid sels))

(define (editor-scroll! ed state vid which)
  (surface-scroll! ed state vid which))

(define (editor-undo! ed state vid)
  (surface-undo! ed state vid))

(define (editor-redo! ed state vid)
  (surface-redo! ed state vid))

(define (editor-kill-line! ed state vid)
  (surface-kill-line! ed state vid))

(define (editor-ensure! ed state vid)
  (surface-ensure! ed state vid))
