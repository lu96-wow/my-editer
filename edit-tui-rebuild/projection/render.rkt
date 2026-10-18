#lang racket

;;; projection/render.rkt —— State + Engine → panels / bytes（投影，不输出）
;;; layer  : projection
;;; effect : 无（纯投影：只读 engine，不写 core；输出交给 runtime）

;;;   project-frame  : state engine -> (values panels view-placements)
;;;                    panels = 平铺面板 + 浮层面板（浮层 deep 更高，叠在上面）
;;;   render-frame   : state engine cache -> (values frame-cache bytes)
;;;
;;; 投影**不写 core**：
;;;   · panels 只引用 engine 里的 view 句柄；
;;;   · view 的 viewport 尺寸由 Runtime 在渲染前调用
;;;     `(engine-sync-views! engine view-placements)`；
;;;   · 本模块不 put-bytes、不 flush。
;;;
;;; 浮层（workspace.floats）是**真的 panel + view**：core 的 screen 里就有它，
;;; 所以出现 / 移动 / 消失都由 core 的增量 diff 负责，这里不做任何擦除。
;;;
;;; region 的每个成员都是 core view（状态栏 / 输入栏也是）：
;;; 文本由各自的同步器写进 buffer，这里只把 view 交给 core。
;;; 所以**没有第二条绘制路径** —— 要显示什么，先有 document。

(provide (struct-out frame-cache)
         project-frame
         project-view-placements
         render-frame)

(require "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/engine.rkt"
         "../projection/geometry.rkt"
         "../projection/status.rkt"
         "../projection/float.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/view/patch.rkt"          ; piece
         "../../core/editor/render.rkt"       ; render-display-patch
         "../../core/text/base/width.rkt"
         "../core-render/main.rkt")

;;; ════════════════ 结果 / 缓存 ════════════════

(struct frame-cache (core) #:transparent)
;; core : core 的 render-cache | #f
;;
;; 只有一项：面板（含浮层）都是真的 core panel，增量 diff 全由 core 负责。

;;; ════════════════ 投影 ════════════════

(define (frame-area state)
  (define w (state-window state))
  (rect 0 0 (window-cols w) (window-rows w)))

(define (active-member reg)
  (for/first ([m (in-list (region-members reg))]
              #:when (equal? (region-member-key m) (region-active reg)))
    m))

;; → (values panels view-placements)
;;   panels          : (listof core panel)
;;   view-placements : (listof (list view-id content-rect)) 给 engine-sync-views!
(define (project-frame state engine)
  (define ws (state-workspace state))
  (define ev (make-engine-view engine))
  (define focus (state-focus state))
  (define-values (rps _cuts) (geometry-solve (workspace-layout ws) (frame-area state)))
  (define panels '())
  (define placements '())
  (for ([rp (in-list rps)])
    (define rid (region-panel-region rp))
    (define reg (workspace-region ws rid))
    (define m (and reg (active-member reg)))
    (define borders (region-panel-borders rp))
    (define r (region-panel-rect rp))
    (define c (region-panel-content rp))
    (cond
      [(and m (view-region-member? m))
       (define vid (region-member-key m))
       (define v (engine-view-object engine vid))
       (when v
         (set! placements (cons (list vid c) placements)))
       (define focused? (and focus (equal? focus vid)))
       (set! panels
             (cons (make-panel v r borders
                               #:face (if focused? 'focused-border 'window-border)
                               #:weight (if focused? 1 0))
                   panels))]
      [else
       ;; 没有成员的 region（刚拆出来的空窗口 / 关光 view 的 panel）：
       ;; 焦点可能正好在它上面（focus = region-id），给它聚焦边框做视觉反馈。
       (define focused? (and focus (equal? focus rid)))
       (set! panels
             (cons (make-panel #f r borders
                               #:face (if focused? 'focused-border 'window-border)
                               #:weight (if focused? 1 0))
                   panels))]))
  ;; 浮层：不在 layout 里，作为 deep 更高的 panel 叠上去。
  ;; 内容仍是 document/view —— core 的 screen 里就有它，擦除/遮挡由 core 的 diff 负责。
  (for ([fp (in-list (project-floats state ev))])
    (define vid (float-panel-view fp))
    (define v (engine-view-object engine vid))
    (when v
      (define r (float-panel-rect fp))
      (define borders float-borders)
      (set! placements (cons (list vid (rect-content r borders)) placements))
      (set! panels
            (cons (make-panel v r borders #:deep 1 #:face 'focused-border)
                  panels))))
  (values (reverse panels) (reverse placements)))

(define (project-view-placements state engine)
  (define-values (_ps placements) (project-frame state engine))
  placements)

;;; ════════════════ 渲染 ════════════════

;; 纯投影：返回新 cache + bytes（不 put）。
;; 调用方应先用 project-view-placements + engine-sync-views! 同步 view 尺寸。
(define (render-frame state engine cache)
  (define-values (panels _placements) (project-frame state engine))
  (define area (frame-area state))
  (define focus-id (state-focus state))
  (define focus-view (and focus-id (engine-view-object engine focus-id)))
  (define core-cache (and (frame-cache? cache) (frame-cache-core cache)))
  (define-values (core-cache* rows sels)
    (render-display-patch panels focus-view
                          (rect-w area) (rect-h area)
                          core-cache))
  (define out (bytes-append (if cache (bytes) (render-clear))
                            (render-pieces (append rows sels))))
  (values (frame-cache core-cache*) out))
