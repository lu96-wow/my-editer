#lang racket

;;; edit3/extension.rkt —— 插件门面（白名单）
;;;
;;; 特性 / 插件只 require 这一个模块，拿到「可用的原语 + 词汇」，而不是把整个 step 透出。
;;; 这样插件不会依赖 step（避免循环），也限制了插件能碰的边界。
;;;
;;; 插件被期望的形态：
;;;   · 用 make-plugin 声明贡献（ops / prompt-kinds / panels / regions / key-tables /
;;;     doc-key-matchers / boot）；
;;;   · op handler : ctx state event args -> (values state (listof effect))；
;;;   · 面板 render : state vid -> (values text (listof (cons line face)))；
;;;   · 需要几何 / 命中用 route 的 ctx；需要改状态用 State + feature-ref / feature-set。

(require "state.rkt" "event.rkt" "effect.rkt" "op.rkt" "prompt.rkt"
         "panels.rkt" "keymap.rkt" "command.rkt" "route.rkt" "hook.rkt"
         "window.rkt" "layout.rkt" "resize.rkt" "adapter.rkt" "plugin.rkt" "fs.rkt"
         "face.rkt" "face-plugin.rkt" "lex.rkt" "kind.rkt" "bracket.rkt")

(provide
 ;; ---------- 插件契约 ----------
 (struct-out plugin) make-plugin

 ;; ---------- State / 值类型 ----------
 (struct-out state) make-state feature-ref feature-set (struct-out rect) (struct-out anchor) (struct-out doc-meta)
 (struct-out tile) (struct-out float) (struct-out item) (struct-out split) (struct-out tiling)
 (struct-out placement) (struct-out handle) (struct-out geometry)
 (struct-out prompt) (struct-out placing)
 editor-tile panel-tile

 ;; ---------- 事件 / 钩子 ----------
 (struct-out key-event) (struct-out text-event) (struct-out cursor-event)
 (struct-out resize-event) (struct-out job-event) (struct-out tick-event)
 (struct-out reaction) reaction* emit
 (struct-out quit-effect) (struct-out log-effect)
 (struct-out save-file) (struct-out open-file)

 ;; ---------- 注册表 ----------
 (struct-out op-registry) make-op-registry op-register op-lookup op-run
 (struct-out prompt-kind-registry) make-prompt-kind-registry prompt-kind-register prompt-kind-lookup

 ;; ---------- 面板 / 区域 ----------
 (struct-out panel-spec) (struct-out panel-registry)
 panel-register panel-lookup panel-names panel-doc-name
 (struct-out region) region-members region-side region-size region-anchor parse-region
 panel-name? panel-vid panel-line panel-name-of-vid
 tree-init tree-ensure tree-rows tree-toggle-dir tree-expand-dir tree-parent-dir
 tree-refresh tree-toggle-hidden tree-relative-path
 buffer-rows buffer-items
 refresh-panels!

 ;; ---------- 窗口 / 布局 / 浮窗 ----------
 wid-vid focused-vid all-wids wid-of-vid has-vid? has-wid? wid-float?
 wid-border set-wid-vid remove-wid*
 fresh-wid raise-float* focus-wid* open-float* open-float-overlay* close-float*
 layout hit solve-axis min-size float-rect
 layout-split-tile layout-remove-wid layout-remove-vid
 layout-resize-boundary layout-set-bases
 layout-fresh-wid layout-tile-vid layout-set-tile-vid layout-tile-border
 layout-find-path layout-add-side layout-add-adjacent
 node-wids layout-vids layout-has? layout-has-wid? layout-wid-of-vid
 float-by-id set-float move-float* resize-float*

 ;; ---------- 编辑 / 读 ----------
 blank-editor add-document-view! add-view! add-panel! close-view close-document
 insert! backspace! delete! nav! select-all! copy! cut! paste! undo! redo!
 set-point! assign! scroll! ensure! screen->point point->screen
 view-did view-document-name view-line view-col view-string view-selection-empty?
 view-id-list document-id-list document-view-list document-name document-string document-handle
 view-size view-left-column face-line! readonly-range! face-batch! face-range! document-face-at

 ;; ---------- 键表 / 命令 / 路由 ----------
 compose-keymaps keymap-add entry-binding entry-scope same-slot?
 parse-binding compile-routes binding-label op? op-tag op-args
 (struct-out route) (struct-out ctx) ctx-placements
 route-input route-input/k guard-and guard-or guard-not always handled pass
 key-is? on-key on-text on-cursor on-resize on-job

 ;; ---------- 文件系统原语 ----------
 fs-read-dir fs-read-file fs-write-file fs-make-file fs-make-dir fs-delete
 fs-dir? fs-file? fs-exists?

 ;; ---------- 高亮（face 插件） ----------
 (struct-out face-plugin) (struct-out face-stack) face-compose face-layers face-runs
 (struct-out palette-color) (struct-out palette-bg)
 refresh-faces-vid! match-brackets
 symbol-char? ident-start? ident-char? line-tokens
 racket-file? racket-applies?)
