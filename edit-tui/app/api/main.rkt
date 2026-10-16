#lang racket

;;; api/main.rkt —— app 公共 API 面入口（聚合）
;;;
;;; 只聚合 api/ 下的功能转发模块：require 这一份即拿到 app 的**可用面**。
;;; 内部实现模块（app/*.rkt）可直接 require，但那份不属于稳定面。
;;;
;;; ═══════════════════════════════════════════════════════════════════
;;; 一句话：事件 → 纯 world-step → intent 列表 → loop 解释并重绘。
;;; 行为不写死在流程里，而是「查注册表」判出来的。
;;; ═══════════════════════════════════════════════════════════════════
;;;
;;; ── 功能模块（api/ → app/） ───────────────────────────────────────
;;;
;;;   intent.rkt      → app/intent.rkt                效果即数据
;;;   world.rkt       → app/world.rkt                  世界状态 + 派生
;;;   panel-ref.rkt   → app/panel-ref.rkt              面板稳定身份
;;;   role.rkt        → app/role.rkt                   leaf 角色注册表
;;;   doc-kind.rkt    → app/doc-kind.rkt               document 类型 → 命令表
;;;   base-keys.rkt   → app/base-keys.rkt              基础小表
;;;   ops.rkt         → app/ops.rkt                    操作原语
;;;   resource.rkt    → app/resource.rkt               资源创建
;;;   step.rkt        → app/step.rkt                   纯状态转移
;;;   render.rkt      → app/render.rkt                 world → bytes
;;;   loop.rkt        → app/loop.rkt                   run-app（唯一不纯）
;;;
;;; ── 最小用法 ──────────────────────────────────────────────────────
;;;
;;;   (require "edit-tui/app/api/main.rkt")
;;;   (define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
;;;   (run-app
;;;     (make-world #:area (rect 0 0 80 24)
;;;                 #:layout (lay 'tb (pane 'editor #:view ev #:role 'editor))
;;;                 #:focus (leaf-ref 'editor)
;;;                 #:keytable (make-keytable my-keys focus-keys)))

(require "intent.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "role.rkt"
         "doc-kind.rkt"
         "base-keys.rkt"
         "ops.rkt"
         "resource.rkt"
         "step.rkt"
         "render.rkt"
         "loop.rkt"
         "plugin.rkt"
         "slot.rkt")

(provide (all-from-out "intent.rkt"
                       "world.rkt"
                       "panel-ref.rkt"
                       "role.rkt"
                       "doc-kind.rkt"
                       "base-keys.rkt"
                       "ops.rkt"
                       "resource.rkt"
                       "step.rkt"
                       "render.rkt"
                       "loop.rkt"
                       "plugin.rkt"
                       "slot.rkt"))
