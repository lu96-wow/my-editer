#lang racket

;;; edit-rebuild/core/theme/theme.rkt —— 主题机制（纯）
;;;
;;; 主题 = face / overlay 符号 -> style + 三张调色板（keyword / word / bracket）。
;;; 颜色由 document 的 face 字段带出，本层只把 face 翻成 style；不认识终端 / ANSI。
;;;
;;; 用哪套配色由 config/theme.rkt 的 require 决定（active-scheme）；本文件据此
;;; 组装唯一一个 default-theme，其余方案不会被加载。
;;; tree / state 的固定 face 在 theme/{tree,state}.rkt。

(require "style.rkt"
         "tree.rkt"
         "state.rkt"
         "scheme.rkt"
         "../config/theme.rkt"
         "../face/face.rkt")

(provide (struct-out theme)
         default-theme
         current-theme theme-style theme-overlay-style)

(struct theme (faces overlays palettes default-style) #:transparent)
;; faces         : hash face-symbol -> style
;; overlays      : hash overlay-symbol -> style
;; palettes      : hash kind-symbol -> (vectorof rgb)   palette-color / palette-bg 取色用
;; default-style : style（face 缺失 / #f 时用）

;;; ---------- 固定 face ----------

(define base-faces
  (hash 'line-number (style (rgb 90 96 110) #f '())               ; 行号栏
        'window-border (style (rgb 105 112 128) #f '())))       ; 窗口边框

(define base-overlays
  (hash 'cursor    (style #f #f '(reverse))                 ; 光标：反色
        'selection (style #f (rgb 58 74 128) '())))         ; 选区：蓝底

(define (merge-hashes . hashes)
  (for/fold ([h (hash)]) ([x (in-list hashes)])
    (for/fold ([h h]) ([(k v) (in-hash x)]) (hash-set h k v))))

;;; ---------- 组装唯一主题 ----------

(define default-theme
  (theme (merge-hashes base-faces tree-faces state-faces)
         base-overlays
         (hash 'keyword (scheme-keyword active-scheme)
               'word    (scheme-word active-scheme)
               'bracket (scheme-bracket active-scheme))
         (style (scheme-fg active-scheme) #f '())))         ; #f 底色 = 终端默认

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
