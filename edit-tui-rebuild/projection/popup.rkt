#lang racket

;;; projection/popup.rkt —— 浮层（弹窗）→ 屏幕矩形 + 绘制片段（纯）
;;;
;;; layer  : projection
;;; effect : 无（纯投影：state + engine-view -> 矩形 / piece）
;;;
;;; 弹窗锚在“某个 view 的光标”上：每帧用 engine-view 读光标在 view 内的位置，
;;; 再加上该 view 所在 region 的内容区原点，得到绝对屏幕坐标。
;;; 位置策略（暂定）：
;;;   · 优先放在光标**下面一行**；下面放不下就放到上面；
;;;   · 水平方向夹在当前 region 内容区里（不跨面板）；
;;;   · 尺寸 = 最长行宽 + 2（边框），高度 = min(行数, max-rows) + 2。
;;;
;;; 只产出数据（rect + lines + selected），字节序列由 core 的 piece 组装。

(provide (struct-out popup-entry)
         project-popups
         popup-entry-pieces
         popup-rect-for)

(require "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/overlay.rkt"
         "../effects/engine.rkt"
         "geometry.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/view/patch.rkt"        ; piece
         "../../core/text/base/width.rkt")

(struct popup-entry (rect lines selected) #:transparent)
;; rect     : 屏幕矩形（含边框）
;; lines    : (listof string)（已按 rect 宽度截断）
;; selected : natural | #f

(define max-rows 10)

;; 某个 popup 在屏幕上的矩形；锚点 view 不可见 / 光标取不到 → #f
(define (frame-area state)
  (define w (state-window state))
  (rect 0 0 (window-cols w) (window-rows w)))

(define (popup-rect-for state ev p)
  (define ws (state-workspace state))
  (define vid (popup-view p))
  (define reg (workspace-view-region ws vid))
  (cond
    [(not reg) #f]
    [else
     (define area (frame-area state))
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
     (define rp (for/first ([x (in-list rps)]
                            #:when (equal? (region-panel-region x) (region-key reg)))
                  x))
     (cond
       [(not rp) #f]
       [else
        (define content (region-panel-content rp))
        (define-values (crow ccol) (engine-view-view-cursor-position ev vid))
        (cond
          [(not crow) #f]
          [else
           (define lines (popup-lines p))
           (define n (length lines))
           (define rows (min n max-rows))
           (define w (+ 2 (for/fold ([m 0]) ([l (in-list lines)])
                            (max m (string-display-width l)))))
           (define h (+ 2 rows))
           (popup-rect content crow ccol w h)])])]))

(define (popup-rect content crow ccol w h)
  (define cw (rect-w content))
  (define ch (rect-h content))
  (define w* (max 4 (min w (max 4 cw))))
  (define h* (max 3 (min h (max 3 ch))))
  ;; 垂直：光标下面一行；放不下就翻到上面
  (define y0 (+ (rect-y content) crow 1))
  (define y (if (<= (+ y0 h*) (+ (rect-y content) ch))
                y0
                (max (rect-y content) (- (+ (rect-y content) crow) h*))))
  ;; 水平：光标列对齐，夹在内容区里
  (define x0 (+ (rect-x content) ccol))
  (define x (max (rect-x content)
                 (min x0 (+ (rect-x content) (- cw w*)))))
  (rect x y w* h*))

;; 所有浮层的投影（当前只有一层，但结构上支持多个）
(define (project-popups state ev)
  (for/list ([p (in-list (workspace-overlays (state-workspace state)))])
    (define r (popup-rect-for state ev p))
    (and r
         (popup-entry r
                     (fit-lines (popup-lines p) (- (rect-w r) 2) (- (rect-h r) 2))
                      (popup-selected p)))))

(define (fit-lines lines w h)
  (for/list ([l (in-list (take lines (min h (length lines))))])
    (truncate-width l w)))

(define (truncate-width s w)
  (cond
    [(<= (string-display-width s) w) s]
    [else
     (let loop ([i 0] [col 0] [acc '()])
       (cond
         [(>= i (string-length s)) (list->string (reverse acc))]
         [else
          (define cw (char-display-width (string-ref s i)))
          (if (> (+ col cw) w)
              (list->string (reverse acc))
              (loop (add1 i) (+ col cw) (cons (string-ref s i) acc)))]))]))

;;; ════════════════ 绘制片段 ════════════════

;; 边框 + 每行文本；选中行用 'selection（反色底），边框用 'focused-border。
(define border-face 'focused-border)
(define selected-face 'selection)

(define (popup-entry-pieces e)
  (define r (popup-entry-rect e))
  (define lines (popup-entry-lines e))
  (define sel (popup-entry-selected e))
  (define w (rect-w r))
  (define h (rect-h r))
  (define x (rect-x r))
  (define y (rect-y r))
  (define inner (- w 2))
  (append
   ;; 上边框
   (list (piece y x (string-append "┌" (make-string inner #\─) "┐") border-face))
   ;; 中间行：│ text… │
   (for/list ([i (in-range (- h 2))])
     (define line (if (< i (length lines)) (list-ref lines i) ""))
     (define pad (max 0 (- inner (string-display-width line))))
     (piece (+ y 1 i) x
            (string-append "│" line (make-string pad #\space) "│")
            (if (and sel (= i sel)) selected-face #f)))
   ;; 下边框
   (list (piece (+ y h -1) x (string-append "└" (make-string inner #\─) "┘") border-face))))
