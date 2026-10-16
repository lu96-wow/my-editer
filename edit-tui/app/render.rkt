#lang racket

;;; app/render.rkt —— world → bytes 的纯投影（唯一不纯：panels-sync! / put-bytes）
;;;
;;; 规则的形状和 core-render 一样：算出 piece，拼成 tui 序列，本模块负责
;;; “何时输出”。world 只描述“画什么”，缓存（cache）由 loop 持有 —— 渲染缓存
;;; 是运行期细节，不进 world。
;;;
;;; 焦点边框（纯投影，不写回 layout / world）：
;;;   core 的一个边框格只能有一个 face，**共享接缝（1 格）**上靠 panel.weight 争色：
;;;   同 deep 时 weight 大者赢。所以焦点 panel 只要 face='focused-border + weight>0，
;;;   它的整圈框（含与邻居共享的缝）就是焦点色；其余 panel 保持各自声明的 face
;;;   （默认 'window-border）= 同一个普通边框色。
;;;
;;; 暂定：
;;;   · panels-sync! 会按 panel 的 content rect 重设 view 视口尺寸，是一次
;;;     对 core 的写。放在这里而不是 step，是因为它只跟“这一帧的布局”有关；
;;;     要更纯粹的话可以把它挪进 loop，在 step 之后、draw 之前调用。
;;;   · 首帧清屏的判断用 cache = #f（与 core 一致）；resize 的残留由 core
;;;     screen-patch 逐格回擦（见 core/view/patch.rkt），这里不额外清屏。

(require tui
         "world.rkt"
         "../core-render/main.rkt"
         "../../core/editor.rkt")

(provide draw-world world-display-panels)

;;; ---------- 焦点边框配色 ----------

(define focus-border-face 'focused-border)   ; 见 theme/frame.rkt
(define focus-border-weight 1)

;; panels 与 refs 严格同序；焦点 ref 对应的 panel 抬 face/weight，其余原样。
(define (focus-decorate ps refs focus)
  (for/list ([p (in-list ps)] [r (in-list refs)])
    (if (equal? r focus)
        (struct-copy panel p [face focus-border-face]
                             [weight (max focus-border-weight (panel-weight p))])
        p)))

;; world → 用于绘制的 panel 列表（world-panels 的焦点边框投影，纯、可测）。
(define (world-display-panels w)
  (define-values (ps refs) (world-panels+refs w))
  (focus-decorate ps refs (world-focus w)))

;; world × 旧 cache → 新 cache（bytes 已 put 出去）。
(define (draw-world w cache)
  (define ps* (world-display-panels w))    ; 纯投影：焦点框换色
  (panels-sync! ps*)                       ; 让 view 视口贴合本帧 panel 尺寸
  (define a (world-area w))
  (define-values (cache* rows seqs)
    (render-display-patch ps* (world-focus-view w) (rect-w a) (rect-h a) cache))
  (put-bytes (bytes-append (if cache (bytes) (render-clear))
                           (render-pieces (append rows seqs))))
  (flush!)
  cache*)
