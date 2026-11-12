#lang racket

;;; edit-tui/editor/api.rkt —— 插件唯一能 require 的 editor 面
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

 ;; State 查询 / 有限 UI 会话更新：不导出 constructor / plugin-states /
 ;; resource 变更入口。helper 同时接受 app-state 和 editor-core。
 state-with-flash
 state-workspace-root
 (struct-out select-drag)
 state-drag
 state-select-drag
 state-find
 state-with-drag
 state-with-select-drag
 state-with-find
 state-with-layout
 state-with-pending
 state-with-input
 state-with-placement
 state-resource-for-view
 state-resource-for-doc
 state-doc-mode
 state-opened-paths
 state-resources
 state-layout
 state-layout-config
 state-area
 state-input
 state-placement
 state-async?

 ;; resource 只读查询：变更入口只在 host-api。
 resource? resource-id resource-doc-id resource-path resource-name
 resource-views resource-mode resource-saved-version
 resources? resources-list resources-find-path
 resources-find-doc resources-find-view resources-opened-paths
 resource-dirty? resource-normalize-path resource-display-path

 (all-from-out "mode.rkt")
 (all-from-out "action.rkt")

 ;; 插件构造面：不导出 host 编排 / editor 实例 / engine / hook registry。
 plugin? make-plugin
 (struct-out command-group)
 guarded-command? make-guarded-command
 make-hook
 (except-out (struct-out edit-context) edit-context-engine)
 (except-out (struct-out change-context) change-context-engine)

 ;; 只读查询：ed + id，不把 engine 句柄交给插件
 editor-view-text
 editor-doc-text
 editor-doc-version
 editor-view-doc-id
 editor-doc-ids
 editor-view-ids-for-doc
 editor-view-point-line
 editor-view-point-column
 editor-view-cursor-screen-position
 editor-view-face-at

 ;; UI view 写回（status / docs / completion 等普通 view）
 editor-set-view-content!
 editor-set-view-cursor!
 editor-set-view-face-track!
 editor-set-view-face-lines!
 editor-set-view-lines!

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

 ;; layout 操作面 + 查询（不导出 layout-context / mouse / engine）
 editor-focus-panel-id
 editor-focus-panel
 editor-focus-panel-kind
 editor-focus-view-id
 editor-focus-view-if-attached!
 editor-focus-content-rect
 editor-visible-editor-panels
 editor-split!
 editor-close!
 editor-focus!
 editor-cycle-editor-view!
 editor-toggle-panel!

 ;; async job：插件只提交 job、读结果；账本写回只在 host runtime。
 job-result-event? job-result-event-id job-result-event-kind
 job-result-event-result job-result-event-tag
 state-submit-job

 ;; timer：插件只 schedule / cancel / 读 event-id；service 安装属于 host。
 timer-event? timer-event-id
 editor-schedule-timer! editor-cancel-timer!

 (all-from-out "overlay.rkt"))

;;; ════════════════ engine 查询 / UI 写回（ed 级） ════════════════

(define (editor-view-text ed vid)
  (engine-view-text (editor-engine ed) vid))
(define (editor-doc-text ed did)
  (engine-doc-text (editor-engine ed) did))
(define (editor-doc-version ed did)
  (engine-doc-version (editor-engine ed) did))
(define (editor-view-doc-id ed vid)
  (engine-view-doc-id (editor-engine ed) vid))
(define (editor-doc-ids ed)
  (engine-doc-ids (editor-engine ed)))
(define (editor-view-ids-for-doc ed did)
  (engine-view-ids-for-doc (editor-engine ed) did))
(define (editor-view-point-line ed vid)
  (engine-view-point-line (editor-engine ed) vid))
(define (editor-view-point-column ed vid)
  (engine-view-point-column (editor-engine ed) vid))
(define (editor-view-cursor-screen-position ed vid)
  (engine-view-cursor-screen-position (editor-engine ed) vid))
(define (editor-view-face-at ed vid line col)
  (engine-view-face-at (editor-engine ed) vid line col))

(define (editor-set-view-content! ed vid lines faces
                                  #:readonly-prefix [readonly-prefix 0]
                                  #:prefix-face [prefix-face #f])
  (engine-set-view-content! (editor-engine ed) vid lines faces
                            #:readonly-prefix readonly-prefix
                            #:prefix-face prefix-face))
(define (editor-set-view-cursor! ed vid line #:column [column 0])
  (engine-set-view-cursor! (editor-engine ed) vid line #:column column))
(define (editor-set-view-face-track! ed vid face-track
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (engine-set-view-face-track! (editor-engine ed) vid face-track
                               #:key key
                               #:base-version base-version))
(define (editor-set-view-face-lines! ed vid face-lines
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (engine-set-view-face-lines! (editor-engine ed) vid face-lines
                               #:key key
                               #:base-version base-version))
(define (editor-set-view-lines! ed vid lines faces line
                                #:column [column 0]
                                #:readonly-prefix [readonly-prefix 0]
                                #:prefix-face [prefix-face #f])
  (engine-set-view-lines! (editor-engine ed) vid lines faces line
                          #:column column
                          #:readonly-prefix readonly-prefix
                          #:prefix-face prefix-face))

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
