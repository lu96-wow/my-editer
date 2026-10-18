#lang racket

;;; plugins/resource/plugin.rkt —— 资源列表 = 一个插件
;;; layer  : plugins/resource
;;; effect : 无（声明）；install-resource-panel! 会建 engine 对象（装配动作）

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
(provide (all-from-out "panel.rkt"))

(require "../../model/state.rkt"
         "../../model/layout.rkt"
         "model.rkt"
         "../../command/key.rkt"
         "../../command/mouse.rkt"
         "../../base/keymap.rkt"
         "../../env/mode.rkt"
         "../../env/environment.rkt"
         "../../env/plugin.rkt"
         "../../bootstrap/panel.rkt"
         "commands.rkt"
         "panel.rkt")

(define pointer-keys
  (keys
   [(mouse 'press 'left) 'pointer-press]
   [(mouse 'move #f)     'pointer-drag]))

(define (resource-plugin-mode)
  (make-mode #:keymaps (list resource-keys pointer-keys) #:fallback 'ignore))

(define (install-resource-panel-state! _engine state _rid vid)
  (plugin-state* state 'resources
                 (λ (r) (resource-panel-set-view r vid))
                 (resource-panel-empty)))

(define (resource-panel-spec)
  (make-panel-spec
                   #:name "*resources*"
                   #:role 'resource
                   #:mode 'resources
                   #:sync sync-resource-panel!
                   #:install install-resource-panel-state!
                   #:hint (fixed 30)
                   #:owner 'resources
                   #:key 'resources))

;; 便捷安装：按 spec 建面板（install 回调负责 store['resources] 的 view-id）。
(define (install-resource-panel! engine state rid)
  (define-values (s1 _vid) (panel-spec-install! engine state rid (resource-panel-spec)))
  s1)

(define (resource-plugin)
  (make-plugin
   'resources
   #:env (make-environment
          #:modes (hash 'resources (resource-plugin-mode))
          #:commands (resource-command-table))
   #:panels (list (resource-panel-spec))))
