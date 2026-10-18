#lang racket

;;; layer  : core-render
;;; effect : 无（纯 piece -> tui 序列）

;;; core-render/render.rkt —— core 渲染数据 -> tui 序列
;;;
;;; 只做一件事：把 core 的渲染值（`piece`）画成 tui 序列。
;;;   · 何时渲染（首帧 / 增量 / 重绘）由外部决定；
;;;   · 怎么组合（core 序列 + 边框序列 + 别的）由外部决定；
;;;   · 何时 put-bytes / 怎么输出，全在外部 —— 本模块不输出、不 flush。
;;;
;;; 序列：真终端是 bytes，tui/char 是 op-seq，两者都直接 put-bytes。
;;;
;;; face 的解释在这里：fg/bg/attrs 都是 tui 风格名，用 style->bytes 取转义序列。
;;; patch.rkt 的 overlay 编码 `(overlay . role)` 在这里解开：先底层 face，再叠角色名。

(require tui "../base/face.rkt"
         "../../core/editor.rkt")

(provide
 render-piece                    ; piece -> tui 序列
 render-pieces                   ; (listof piece) -> tui 序列
 render-clear                    ; -> tui 序列（清屏）
 face-fragment)                  ; #f | symbol | face -> tui 序列

;; 序列拼接（滤掉 #f；tui 拼 bytes，tui/char 拼 op-seq）。内部工具，不外露。
(define (fragment . parts) (apply bytes-append (filter values parts)))

;;; ---------- 一格 -> 序列 ----------

(define (render-piece p)
  (fragment
   (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
   (attr-fragment (piece-attr p))
   (format-content (piece-text p))
   format-reset))

(define (render-pieces ps)
  (apply fragment (map render-piece ps)))

;; attr：face（文本格）或 (overlay . face)（光标 / 选区格）。
(define (attr-fragment attr)
  (cond
    [(pair? attr) (fragment (face-fragment (cdr attr)) (style-fragment (car attr)))]
    [else (face-fragment attr)]))

;; face 值 -> 序列。
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

;; 分量符号 -> 序列（未知名字 -> 空，no-op）。
(define (style-fragment name)
  (and name (style->bytes name)))

;;; ---------- 清屏 ----------

(define (render-clear) (fragment format-screen-clear))
