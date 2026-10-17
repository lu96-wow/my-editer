#lang racket

;;; bootstrap/resource-plugin.rkt —— 资源列表 = 一个插件
;;;
;;; 贡献：
;;;   panel-spec      : 面板身份（名字 / role / mode / 每帧同步）
;;;   install         : 宿主给 region-id，插件把 view 装好
;;;   mode 'resources : 面板内键表（fallback 'ignore）
;;;   commands        : resource-command-table
;;;
;;; placement（把 view 放进某个 panel）不在这个插件里：它是框架级交互
;;; （见 bootstrap/commands.rkt 的 placement 段 + workspace.placement）。
;;; 本插件只负责“发起”：r / Enter 设 workspace.placement。
;;;
;;; 面板自己的 State 切片在 store['resources]（model/resources.rkt）。

(provide resource-plugin
         resource-panel-spec
         resource-plugin-mode
         install-resource-panel!)
(provide (all-from-out "resource-panel.rkt"))

(require "../model/state.rkt"
         "../model/resources.rkt"
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         "../base/keymap.rkt"
         "../env/mode.rkt"
         "../env/environment.rkt"
         "../bootstrap/plugin.rkt"
         "resource-commands.rkt"
         "resource-panel.rkt")

(define pointer-keys
  (keys
   [(mouse 'press 'left) 'pointer-press]
   [(mouse 'move #f)     'pointer-drag]))

(define (resource-plugin-mode)
  (make-mode #:keymaps (list resource-keys pointer-keys) #:fallback 'ignore))

(define (resource-panel-spec)
  (make-panel-spec 'resources
                   #:name "*resources*"
                   #:role 'resource
                   #:mode 'resources
                   #:sync sync-resource-panel!))

;; 便捷安装：按 spec 建面板 + 记面板 view-id。
(define (install-resource-panel! engine state rid)
  (define-values (s1 vid) (panel-spec-install! engine state rid (resource-panel-spec)))
  (plugin-state* s1 'resources
                 (λ (r) (resource-panel-set-view r vid))
                 (resource-panel-empty)))

(define (resource-plugin)
  (make-plugin
   'resources
   #:env (make-environment
          #:modes (hash 'resources (resource-plugin-mode))
          #:commands (resource-command-table))
   #:panels (list (resource-panel-spec))))
