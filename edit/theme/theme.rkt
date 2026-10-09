#lang racket

;;; edit/theme/theme.rkt —— 主题机制 + 默认主题（纯）
;;;
;;; 主题 = face / overlay 符号 -> style。颜色是哪个 face 由 document 的 face 字段带出来，
;;; 本层只负责「face 符号 -> style」；不认识终端 / ANSI，后端负责翻成转义序列。
;;;
;;; 分块配置：
;;;     theme/tree.rkt    tree-faces    文件树
;;;     theme/state.rkt   state-faces   状态窗口
;;;     本文件            base-faces    编辑器 / overlay / 默认

(require "style.rkt"
         "tree.rkt"
         "state.rkt"
         "syntax.rkt"
         "words.rkt"
         "brackets.rkt"
         "../core/face.rkt")

(provide (struct-out theme)
         default-theme current-theme
         theme-style theme-overlay-style)

(struct theme (faces overlays palettes default-style) #:transparent)
;; faces         : hash face-symbol -> style
;; overlays      : hash overlay-symbol -> style
;; palettes      : hash kind-symbol -> (vectorof rgb)   palette-color 取色用
;; default-style : style（face 缺失 / #f 时用）

;;; ---------- 基础分块 ----------

(define base-faces
  (hash 'line-number (style (rgb 90 96 110) #f '())))       ; 行号栏

(define base-overlays
  (hash 'cursor    (style #f #f '(reverse))                 ; 光标：反色
        'selection (style #f (rgb 58 74 128) '())))         ; 选区：蓝底

;; #f 表示「终端默认」：不设颜色，后端不输出任何序列。
(define default-style (style #f #f '()))

;;; ---------- 组装 ----------

(define (merge-hashes . hashes)
  (for/fold ([h (hash)]) ([x (in-list hashes)])
    (for/fold ([h h]) ([(k v) (in-hash x)]) (hash-set h k v))))

(define default-theme
  (theme (merge-hashes base-faces tree-faces state-faces)
         base-overlays
         (merge-hashes syntax-palettes word-palettes bracket-palettes)
         default-style))

;;; ---------- 查询 ----------

;; 调色板取色：index 对色板长度取模。
(define (palette-ref t kind index)
  (define v (hash-ref (theme-palettes t) kind #f))
  (and v (positive? (vector-length v)) (vector-ref v (modulo index (vector-length v)))))

(define (theme-style t face)
  (cond
    ;; 分层：逐层解析 style，逐分量叠加（后层覆盖前层）。
    [(face-stack? face)
     (define ls (face-stack-layers face))
     (cond
       [(null? ls) (theme-default-style t)]
       [else (for/fold ([st (theme-style t (first ls))])
                       ([lyr (in-list (rest ls))])
               (style-over st (theme-style t lyr)))])]
    [(palette-color? face) (style (palette-ref t (palette-color-kind face) (palette-color-index face))
                                  #f '())]
    [(palette-bg? face) (style #f (palette-ref t (palette-bg-kind face) (palette-bg-index face))
                               '())]
    [else (hash-ref (theme-faces t) face (theme-default-style t))]))

(define (theme-overlay-style t ov)
  (and ov (hash-ref (theme-overlays t) ov #f)))

;; 当前主题（后端每帧读；纯参数，不碰终端）。
(define current-theme (make-parameter default-theme))
