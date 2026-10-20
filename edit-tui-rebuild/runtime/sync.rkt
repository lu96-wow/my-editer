#lang racket

;;; edit-tui-rebuild/runtime/sync.rkt —— 每帧 UI panel 同步
;;;
;;; 顺序有讲究：
;;;   1. input-reconcile   先把「prompt <-> 输入栏 view」这个状态不变量落实
;;;                        （可能切换 status panel 的 active view）
;;;   2. sync-panel-sizes! 再按最新布局把每个 active view 的 viewport 尺寸落好
;;;   3. 各 UI 面板写内容   尺寸对了再写，否则 input 会因为 viewport 还是 1x1
;;;                        把水平滚动（left-column）推过头，提示就看不见了
;;;
;;; 编辑器的 buffer 内容由命令 / action 写，不需要这里同步。

(require "../app/state.rkt"
         "../layout/api.rkt"
         "../render/layout.rkt"
         "engine.rkt"
         "../filetree/panel.rkt"
         "../chrome/status.rkt"
         "../chrome/input.rkt")

(provide sync-ui!)

;; 布局几何 -> core panel -> panels-sync!（写 active view 的 viewport 尺寸）
(define (sync-panel-sizes! state engine)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (when (and layout area)
    (layout-sync! layout area
                  #:focus-panel (layout-focus layout)
                  #:view-object (λ (vid) (engine-view-object engine vid)))))

(define (sync-ui! state engine)
  ;; 输入栏开关是状态迁移：先做，才能把新 active view 的尺寸同步对
  (define s0 (input-reconcile state))
  (sync-panel-sizes! s0 engine)
  (define s1 (sync-filetree! s0 engine))
  (define s2 (input-sync! s1 engine))
  (sync-status! s2 engine))
