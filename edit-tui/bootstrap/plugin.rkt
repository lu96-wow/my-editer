#lang racket

;;; layer  : bootstrap
;;; effect : **装配**：按 owner 撤销 env 贡献 + 清插件 store + 卸面板
;;;
;;; bootstrap/plugin.rkt —— 插件卸载的高层入口
;;;
;;; 三件事分开做，谁拥有谁负责：
;;;   env      : environment-remove-owner（从 base + 其他 contributions 重建）
;;;   store    : plugin-state-clear（一个插件只占 store[plugin-id] 一个 key）
;;;   panel    : panel-uninstall!（需要宿主告诉它装在哪几个 region-id）
;;;
;;; 为什么 region-id 由调用方给：
;;;   布局位置是宿主策略，env 层 / 插件描述符里没有绝对坐标；
;;;   插件可以在多个 region 安装同一个面板，也可以共用 sidebar。
;;;   所以 plugin-uninstall! 不猜布局，只接收 `#:regions`。
;;;
;;; 用法：
;;;   (define-values (env' state')
;;;     (plugin-uninstall! engine state env 'filetree #:regions (list sidebar-rid)))

(provide plugin-uninstall!)

(require racket/list
         "../env/extension.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../effects/panel.rkt")

(define (plugin-uninstall! engine state env owner
                           #:regions [regions '()])
  (unless (symbol? owner)
    (error 'plugin-uninstall! "owner 要是 symbol：~a" owner))
  ;; 1. 按 workspace.panel-index 找到该 owner 安装的 view / region，
  ;;    只卸这些 view；共享 region 里的其它面板保留。
  (define ws0 (state-workspace state))
  (define registered-vids (workspace-panel-views-by-owner ws0 owner))
  (define registered-rids (workspace-panel-regions-by-owner ws0 owner))
  (define s1
    (for/fold ([s state]) ([vid (in-list registered-vids)])
      (panel-uninstall-view! engine s vid)))
  ;; 2. view 都卸完后，空 region 连 region / layout leaf 一起收掉。
  (define s2
    (for/fold ([s s1]) ([rid (in-list registered-rids)])
      (define ws (state-workspace s))
      (if (and (workspace-region ws rid)
               (null? (workspace-region-views ws rid)))
          (panel-uninstall! engine s rid)
          s)))
  ;; 3. 显式 #:regions 仍然按整块 region 卸载（兼容 / 非注册面板）。
  (define s3
    (for/fold ([s s2]) ([rid (in-list regions)])
      (panel-uninstall! engine s rid)))
  (values (environment-remove-owner env owner)
          (plugin-state-clear s3 owner)))
