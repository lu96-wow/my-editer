#lang racket

;;; edit-tui-rebuild/boot/sync.rkt —— 每帧 UI panel 同步
;;;
;;; 顺序有讲究：
;;;   1. input-reconcile   落实「prompt / request <-> 输入栏 view」不变量，
;;;                        挤占插件请求时 on-done 可能产生 action（先跑掉）
;;;   2. sync-panel-sizes! 按最新布局把每个 active view 的 viewport 尺寸落好
;;;   3. 各 UI 面板写内容   尺寸对了再写，否则 input 会因为 viewport 还是 1x1
;;;                        把水平滚动（left-column）推过头，提示就看不见了
;;;
;;; 编辑器的 buffer 内容由命令 / action 写，不需要这里同步。

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "../render/layout.rkt"
         "actions.rkt"
         "../filetree/sync.rkt"
         "../chrome/status.rkt"
         "../chrome/input.rkt")

(provide sync-ui!
         default-sync-hooks)

;; 布局几何 -> core panel -> panels-sync!（写 active view 的 viewport 尺寸）
(define (sync-panel-sizes! state engine)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (when (and layout area)
    (layout-sync! layout area
                  #:focus-panel (layout-focus layout)
                  #:view-object (λ (vid) (engine-view-object engine vid)))))

;; 默认插件 sync 顺序；宿主可以传 #:hooks 覆盖。
(define default-sync-hooks
  (list sync-filetree! input-sync! sync-status!))

(define (sync-ui! state engine #:hooks [hooks default-sync-hooks])
  ;; 输入栏开关是状态迁移：先做（可能挤占插件请求并产生 action），
  ;; 尺寸也要在写内容之前同步对。
  (define-values (s0 actions) (input-reconcile state))
  (define s0* (run-actions s0 engine actions))
  (sync-panel-sizes! s0* engine)
  (for/fold ([state s0*])
            ([hook (in-list hooks)])
    (hook state engine)))
