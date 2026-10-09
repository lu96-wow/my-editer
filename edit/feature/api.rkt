#lang racket

;;; edit/feature/api.rkt —— 特性门面（**白名单**）
;;;
;;; 特性（feature）只 require 这一个模块。这里显式列出特性可用的原语，
;;; 而不是把整个 session 全盘透出——内核适配（session-ed-*）、渲染
;;; （session-patch / -rectangles / -views）、结构手术（close/hide）不进特性层。
;;;
;;; 特性被期望的运行方式：
;;;     · 自带 cmd-* + handler，挂到 handler 链（session-add-handler）
;;;     · handler 里对 session 的改动走这里白名单里的原语
;;;     · 需要别的功能时发命令，用 step 派发，而不是直接调操作函数
;;;     · 需要瞬态叠加窗口（补全弹窗等）时用 float / session-float-open / -close
;;;
;;; 例外：需要**文件资源**的特性（tree / buffers / document）额外 require
;;; document/document.rkt 与 document/fs.rkt。这是「特性组合资源能力」的有意依赖。

(require "../session.rkt"
         "../command/command.rkt"
         "../command/key.rkt"
         "../core/keymap.rkt"
         "../core/ids.rkt")

(provide
 ;; 面板（状态窗口）构造与查询
 panel panel? panel-id panel-vid panel-refresh panel-keys panel-region panel-axis panel-size
 panel-doc
 session-add-panel session-panel-vid session-panel-dids session-dock-vid?

 ;; 会话构造 / 文档 / 视图
 session-add-document
 session-document-ids session-document-name
 session-view-ids-of session-view-did
 session-view-point-line session-view-point-column session-view-string
 session-edit-vid session-focus-vid session-prefix
 session-width session-height
 session-visible? session-set-visible

 ;; 视图结构（显示 / 分屏）
 session-show-view session-split-view

 ;; 浮动窗口（瞬态叠加）：构造 + 开关 + 几何 + 去重
 float float? float-vid float-keys float-x float-y float-w float-h float-deep
 session-floats session-float session-float-add session-float-remove
 session-float-open session-float-close session-float-drop
 session-float-move session-float-set
 session-view-cursor-screen session-view-point->screen
 session-float-dids

 ;; 输入层（模态键表）
 layer layer-id layer-keys session-layer-push session-layer-pop session-layer-active?

 ;; 内容写回 / 区间替换
 session-ed-assign! session-ed-replace!

 ;; 视图定位（面板内部光标定位）
 session-ed-set-point!

 ;; 键 / 命令消费 + 生命周期通知
 session-add-handler
 hook hook? hook-point hook-proc session-add-hook
 session-prompt-open session-refresh
 session-log session-log! session-log-close session-log-toggle

 ;; 文档域查询（tree 着色 / 去重用）
 session-file-dids session-file-path

 ;; 以下整包透出：命令数据与构造（cmd-* / key / kbd）、键表
 (all-from-out "../command/command.rkt"
               "../command/key.rkt"
               "../core/keymap.rkt"
               "../core/ids.rkt"))
