#lang racket

;;; plugins/filetree/plugin.rkt —— 文件树 = 一个插件
;;; layer  : plugins/filetree
;;; effect : 无（声明）；install-filetree-panel! 会建 engine 对象（装配动作）

;;; 插件贡献四样东西（全部是数据 + 一个已存在的同步函数）：
;;;
;;;   panel-spec      : 面板身份（名字 / role / mode / 每帧同步）
;;;   install         : 宿主给 region-id，插件把 view/root/expanded 装好
;;;   mode 'filetree  : 树内键表（只读 viewer，fallback 'ignore）
;;;   commands        : filetree-command-table
;;;   input-commands  : 创建文件 / 文件夹 / 删除确认
;;;   rule 'always    : C-b 显隐（**规则**而不是 global keymap，
;;;                     避免覆盖框架的 global 表）
;;;
;;; 面板的安装仍然是宿主的动作（需要 region-id 与 layout 位置）：
;;;   (define-values (state' vid) (panel-spec-install! engine state (filetree-panel-spec) rid))
;;;   (install-filetree-panel! engine state rid root)  ; 便捷版：装 + 设 workspace.root
;;;
;;; 面板自己的 State 切片在 store['filetree]（model/filetree.rkt）。

(provide filetree-plugin
         filetree-panel-spec
         filetree-plugin-mode
         install-filetree-panel!)
;; 宿主只需要 require 插件：安装 / 同步 / view 查询都在这里。
(provide (all-from-out "panel.rkt")
         (all-from-out "scan.rkt"))

(require "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt"
         "../../command/key.rkt"
         "../../command/mouse.rkt"
         "../../base/keymap.rkt"
         "../../env/mode.rkt"
         "../../env/environment.rkt"
         "../../env/rule.rkt"
         "../../env/plugin.rkt"
         "../../bootstrap/panel.rkt"
         "commands.rkt"
         "panel.rkt")

(define pointer-keys
  (keys
   [(mouse 'press 'left) 'pointer-press]
   [(mouse 'move #f)     'pointer-drag]))

(define (filetree-plugin-mode)
  (make-mode #:keymaps (list filetree-keys pointer-keys) #:fallback 'ignore))

;; panel-spec 的 install：面板创建后写 store['filetree] 的 view-id，
;; 并把 workspace.root 展开（root 由便捷安装先写进 workspace）。
(define (install-filetree-panel-state! _engine state _rid vid)
  (define root (workspace-root (state-workspace state)))
  (plugin-state*
   state 'filetree
   (λ (f)
     (define f1 (if (or (not root) (string=? root "") (filetree-expanded? f root))
                    f
                    (filetree-toggle-expand f root)))
     (filetree-set-view f1 vid))
   (empty-filetree)))

(define (filetree-panel-spec)
  (make-panel-spec
                   #:name "*filetree*"
                   #:role 'filetree
                   #:mode 'filetree
                   #:sync sync-filetree-panel!
                   #:install install-filetree-panel-state!
                   #:hint (fixed 30)
                   #:owner 'filetree
                   #:key 'filetree))

;; 便捷安装：先写 workspace.root，再按 spec 装面板（install 回调负责 store / 展开）。
(define (install-filetree-panel! engine state rid root)
  (define root* (filetree-normalize-path root))
  (define state* (state-workspace* state (λ (ws) (workspace-set-root ws root*))))
  (define-values (s1 _vid) (panel-spec-install! engine state* rid (filetree-panel-spec)))
  s1)

(define (filetree-plugin)
  (make-plugin
   'filetree
   #:env (make-environment
          #:modes (hash 'filetree (filetree-plugin-mode))
          #:commands (filetree-command-table)
          #:input-commands filetree-input-commands
          ;; 全局键用规则贡献：不覆盖框架的 'global 表。
          #:rules (list (make-rule 'always (keys [(key 'b 'ctrl) 'toggle-filetree]))))
   #:panels (list (filetree-panel-spec))))
