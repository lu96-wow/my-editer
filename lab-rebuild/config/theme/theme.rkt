#lang racket

(require "../../base/face.rkt")

;;; lab-rebuild/config/theme/theme.rkt —— 主题机制（纯）
;;;
;;; 主题 = face / overlay 符号 → 颜色。颜色是 #f（不设，交给默认）或 (r g b)（各分量 0-255）。
;;; 本文件不认识终端 / ANSI / racket-tui —— 后端负责把颜色翻成转义序列。
;;;
;;;   faces          : hash  face-symbol    -> (list fg bg)
;;;   overlays       : hash  overlay-symbol -> (list fg bg)
;;;   default-face   : (list fg bg)          未登记 face 的回落
;;;   palettes       : hash  kind-symbol -> vector of (list fg bg)   动态 face 取模
;;;
;;; 动态 face（见 base/face.rkt）：palette-color 按 kind 找色板、按 index 取模。
;;; 所以插件 / view-model 只产出逻辑 face（symbol 或 palette-color），颜色全在这里决定。

(provide (struct-out theme)
         theme-face-colors theme-overlay-colors)

(struct theme (faces overlays default-face palettes) #:transparent)

(define (palette-ref t kind index)
  (define v (hash-ref (theme-palettes t) kind #f))
  (cond
    [(or (not v) (zero? (vector-length v))) (values #f #f)]
    [else
     (define c (vector-ref v (modulo index (vector-length v))))
     (values (car c) (cadr c))]))

(define (theme-face-colors t face)
  (cond
    ;; 分层：逐层解析 (fg bg)，逐分量合并（后层覆盖前层；#f = 该分量不覆盖）。
    [(face-stack? face)
     (for/fold ([fg #f] [bg #f]) ([lyr (in-list (face-stack-layers face))])
       (define-values (f b) (theme-face-colors t lyr))
       (values (or f fg) (or b bg)))]
    [(palette-color? face) (palette-ref t (palette-color-kind face) (palette-color-index face))]
    [else
     (define c (or (hash-ref (theme-faces t) face #f) (theme-default-face t)))
     (values (car c) (cadr c))]))

(define (theme-overlay-colors t ov)
  (define c (hash-ref (theme-overlays t) ov #f))
  (if c (values (car c) (cadr c)) (values #f #f)))
