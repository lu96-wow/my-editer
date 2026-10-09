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
         "state.rkt")

(provide (struct-out theme)
         default-theme current-theme
         theme-style theme-overlay-style)

(struct theme (faces overlays default-style) #:transparent)
;; faces         : hash face-symbol -> style
;; overlays      : hash overlay-symbol -> style
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

(define (merge-faces . hashes)
  (for/fold ([h (hash)]) ([x (in-list hashes)])
    (for/fold ([h h]) ([(k v) (in-hash x)]) (hash-set h k v))))

(define default-theme
  (theme (merge-faces base-faces tree-faces state-faces)
         base-overlays
         default-style))

;;; ---------- 查询 ----------

(define (theme-style t face)
  (hash-ref (theme-faces t) face (theme-default-style t)))

(define (theme-overlay-style t ov)
  (and ov (hash-ref (theme-overlays t) ov #f)))

;; 当前主题（后端每帧读；纯参数，不碰终端）。
(define current-theme (make-parameter default-theme))
