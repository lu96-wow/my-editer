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
         "../edit/api.rkt"
         "../filetree/sync.rkt"
         "../resources/sync.rkt"
         "../chrome/status.rkt"
         "../chrome/input.rkt")

(provide sync-ui!
         sync-ui/panels!)

;; 布局几何 -> core panel -> panels-sync!（写 active view 的 viewport 尺寸）。
;; 返回值就是本帧的 panels，render-frame 可以直接复用，避免再投影一次。
(define (sync-panel-sizes! state engine #:solution [solution #f])
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (and layout area
       (layout-sync! layout area
                     #:focus-panel (layout-focus layout)
                     #:view-object (λ (vid) (engine-view-object engine vid))
                     #:solution solution)))

;; 显式顺序：输入状态机 -> 尺寸 -> 各面板内容 -> 编辑器着色。
;; 将来补全等阶段也在这里显式插入，不做插件 sync callback。
(define (sync-ui/panels! state engine #:solution [solution #f])
  (define-values (s0 actions) (input-reconcile state))
  (define s0* (run-actions s0 engine actions))
  (define panels (sync-panel-sizes! s0* engine #:solution solution))
  (define s1 (sync-filetree! s0* engine))
  (define s1* (sync-resource-panel! s1 engine))
  ;; 使用 pending-doc-changes 更新颜色缓存；不消费，completion 等阶段仍可读取。
  (define s2 (sync-editor-colors! s1* engine))
  (define s3 (input-sync! s2 engine))
  (define s4 (sync-status! s3 engine))
  (values s4 panels))

(define (sync-ui! state engine #:solution [solution #f])
  (let-values ([(state* _panels)
                (sync-ui/panels! state engine #:solution solution)])
    state*))
