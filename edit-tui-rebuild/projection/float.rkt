#lang racket

;;; projection/float.rkt —— 浮层 region → 屏幕矩形（纯）
;;;
;;; layer  : projection
;;; effect : 无（纯投影：state + engine-view -> 矩形）
;;;
;;; 浮层**不是**额外绘制的像素：它就是一个 region + view（buffer 支撑），只是不在
;;; layout 树里，绘制时作为一块 deep 更高的 panel 交给 core 合成。
;;; 好处：擦除 / 移动 / 遮挡全部由 core 的增量 diff 负责（core 的 screen 里就有它）。
;;;
;;; 位置策略（暂定）：
;;;   · 尺寸 = 文档最长行 + 2（边框），高度 = min(行数, max-rows) + 2；
;;;   · 贴在 anchor view 的**光标下方一行**；下面放不下就翻到上方；
;;;   · 水平夹在 anchor 所在 region 的内容区里。

(provide (struct-out float-panel)
         project-floats
         float-panel-at
         float-borders)

(require "../model/state.rkt"
         "../model/workspace.rkt"
         "../effects/engine.rkt"
         "geometry.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/text/base/width.rkt")

(struct float-panel (float region view rect) #:transparent)
;; float  : float 结构（model/workspace.rkt）
;; region : region-id
;; view   : view-id
;; rect   : 屏幕矩形（含边框）

(define float-borders '(up down left right))
(define max-rows 10)

(define (frame-area state)
  (define w (state-window state))
  (rect 0 0 (window-cols w) (window-rows w)))

;; 浮层文档的行（用 engine-view 读文本；view 的文本就是文档文本）
(define (float-lines ev view)
  (define text (engine-view-view-text ev view))
  (if text (string-split text "\n") '()))

;; 浮层想要的尺寸（内容格，不含边框）
(define (float-size ev view)
  (define lines (float-lines ev view))
  (define rows (min (length lines) max-rows))
  (define w (for/fold ([m 1]) ([l (in-list lines)])
              (max m (string-display-width l))))
  (values (max 1 w) (max 1 rows)))

;; anchor view 的内容区 + 光标位置（用来定位）
(define (anchor-area state ev anchor)
  (define ws (state-workspace state))
  (define reg (and anchor (workspace-view-region ws anchor)))
  (cond
    [(not reg) #f]
    [else
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) (frame-area state)))
     (define rp (for/first ([x (in-list rps)]
                            #:when (equal? (region-panel-region x) (region-key reg)))
                  x))
     (cond
       [(not rp) #f]
       [else
        (define-values (crow ccol) (engine-view-view-cursor-position ev anchor))
        (and crow (values (region-panel-content rp) crow ccol))])]))

(define (float-rect state ev f)
  (define anchor (float-anchor f))
  (define-values (cw ch) (float-size ev (float-view f)))
  ;; 含边框的目标尺寸
  (define w (+ cw 2))
  (define h (+ ch 2))
  (cond
    [(not anchor)
     (rect 0 0 (min w (window-cols (state-window state)))
           (min h (window-rows (state-window state))))]
    [else
     (define-values (content crow ccol) (anchor-area state ev anchor))
     (cond
       [(not content)
        (rect 0 0 (min w (window-cols (state-window state)))
              (min h (window-rows (state-window state))))]
       [else
        (define aw (rect-w content))
        (define ah (rect-h content))
        (define w* (max 4 (min w (max 4 aw))))
        (define h* (max 3 (min h (max 3 ah))))
        (define y0 (+ (rect-y content) crow 1))
        (define y (if (<= (+ y0 h*) (+ (rect-y content) ah))
                      y0
                      (max (rect-y content) (- (+ (rect-y content) crow) h*))))
        (define x0 (+ (rect-x content) ccol))
        (define x (max (rect-x content)
                       (min x0 (+ (rect-x content) (- aw w*)))))
        (rect x y w* h*)])]))

(define (project-floats state ev)
  (for/list ([f (in-list (workspace-floats (state-workspace state)))])
    (float-panel f (float-region f) (float-view f) (float-rect state ev f))))

;; 鼠标命中：浮层叠在最上面，先查它们。命中 → 该浮层的 view-id。
(define (float-panel-at state ev row col)
  (for/first ([fp (in-list (project-floats state ev))]
              #:when (rect-contains? (float-panel-rect fp) col row))
    (float-panel-view fp)))
