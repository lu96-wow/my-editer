#lang racket

;;; app/render.rkt —— world → bytes 的纯投影（唯一不纯：panels-sync! / put-bytes）
;;;
;;; 规则的形状和 core-render 一样：算出 piece，拼成 tui 序列，本模块负责
;;; “何时输出”。world 只描述“画什么”，缓存（cache）由 loop 持有 —— 渲染缓存
;;; 是运行期细节，不进 world。
;;;
;;; 暂定：
;;;   · panels-sync! 会按 panel 的 content rect 重设 view 视口尺寸，是一次
;;;     对 core 的写。放在这里而不是 step，是因为它只跟“这一帧的布局”有关；
;;;     要更纯粹的话可以把它挪进 loop，在 step 之后、draw 之前调用。
;;;   · 首帧清屏的判断用 cache = #f（与 core 一致）。

(require tui
         "world.rkt"
         "../core-render/main.rkt"
         "../../core/editor.rkt")

(provide draw-world)

;; world × 旧 cache → 新 cache（bytes 已 put 出去）。
(define (draw-world w cache)
  (define ps (world-panels w))
  (panels-sync! ps)                       ; 让 view 视口贴合本帧 panel 尺寸
  (define a (world-area w))
  (define-values (cache* rows seqs)
    (render-display-patch ps (world-focus-view w) (rect-w a) (rect-h a) cache))
  (put-bytes (bytes-append (if cache (bytes) (render-clear))
                           (render-pieces (append rows seqs))))
  (flush!)
  cache*)
