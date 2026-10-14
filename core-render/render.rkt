#lang racket

;;; core-render/render.rkt —— core 渲染数据 -> 可渲染片段（用 racket-tui 画）
;;;
;;; 纯函数式：给渲染数据，返回可直接 put-bytes 的片段。
;;;   · 何时渲染（首帧 / 增量 / 重绘）由外部决定；
;;;   · 多帧 / 多来源怎么组合由外部决定（片段可 append）；
;;;   · 本模块不持有上一帧、不自己 diff、不自己 flush。
;;;
;;; 片段：真终端是 bytes，tui/char 是 op-seq，两者都直接 put-bytes。
;;;
;;; face 的解释在这里：fg/bg/attrs 都是 tui 风格名，用 style->bytes 取转义序列。
;;; patch.rkt 的 overlay 编码 `(overlay . face)` 在这里解开：先底层 face，再叠 overlay 名。

(require "backend.rkt" "face.rkt"
         "../core/editor.rkt")

(provide
 ;; 基础片段
 render-piece                    ; piece -> 片段（定位 + 样式 + 文本 + 复位）
 render-pieces                   ; (listof piece) -> 片段
 render-clear                    ; -> 片段
 ;; 工具
 emit!                           ; 片段 -> void（薄壳，外部也可直接 put-bytes）
 face-fragment)                  ; face | #f -> 片段（单独用得到时）

;;; ---------- 一格 -> 片段 ----------

(define (render-piece p)
  (fragment
   (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
   (attr-fragment (piece-attr p))
   (format-content (piece-text p))
   format-reset))

(define (render-pieces ps)
  (apply fragment (map render-piece ps)))

;; attr：face（渲染格）或 (overlay . face)（光标 / 选区格）。
(define (attr-fragment attr)
  (cond
    [(pair? attr) (fragment (face-fragment (cdr attr)) (style-fragment (car attr)))]
    [else (face-fragment attr)]))

;; face 值 -> 片段。
;;   #f      -> 默认，无样式
;;   symbol  -> core 自己产生的裸符号 face（如行号栏 'line-number）：整个当一个风格名查
;;   face    -> fg / bg / attrs 三分量分别查（分量都是符号）
(define (face-fragment f)
  (cond
    [(not f) #f]
    [(symbol? f) (style-fragment f)]
    [else
     (fragment
      (style-fragment (face-fg f))
      (style-fragment (face-bg f))
      (apply fragment (map style-fragment (face-attrs f))))]))

;; 分量符号 -> 片段（未知名字 -> 空，no-op）。
(define (style-fragment name)
  (and name (style->bytes name)))

;;; ---------- 清屏 ----------

(define (render-clear) (fragment format-screen-clear))

(define (emit! frag) (put-bytes frag))
