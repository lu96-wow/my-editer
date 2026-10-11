#lang racket

;;; core/theme.rkt —— 主题**编码**：命名 face → ANSI 字节
;;;
;;; 调色板（face 名字 → style 值）在 config/theme.rkt（纯数据、可配置）；
;;; 本模块只做 style → 真彩色 / 256 色 / 属性的翻译，后端只调 attr-bytes。
;;;
;;; core 的 piece-attr 形态：
;;;   (render face)      普通文本格，face = 名字（符号）| #f
;;;   (cursor . face)    光标格
;;;   (selection . face) 选区格

(provide face-bytes attr-bytes
         style style-fg style-bg style-attrs theme-ref)

(require (prefix-in t: tui)
         "../config/theme.rkt"
         "face.rkt")

;;; ---------- 颜色 → ANSI ----------

(define (color-bytes fg? c)
  (cond
    [(not c) #""]
    [(and (pair? c) (eq? (car c) 'rgb))
     (if fg? (t:format-rgb-fg-base (cadr c) (caddr c) (cadddr c))
             (t:format-rgb-bg-base (cadr c) (caddr c) (cadddr c)))]
    [(exact-nonnegative-integer? c)
     (if fg? (t:format-256-fg-base c) (t:format-256-bg-base c))]
    [else #""]))

(define attr-table
  (hash 'bold t:format-bold 'dim t:format-dim 'italic t:format-italic 'underline t:format-underline))

(define (style-bytes st)
  (bytes-append
   (color-bytes #t (style-fg st))
   (color-bytes #f (style-bg st))
   (apply bytes-append (for/list ([a (in-list (style-attrs st))]) (hash-ref attr-table a #"")))))

;;; ---------- face → 字节 ----------

(define (face->style f)
  (cond [(not f) #f]
        [(style? f) f]
        [(symbol? f) (theme-ref f)]
        [else #f]))

;; 分层叠加：后层非 #f 的分量覆盖前层；attrs 累积。
(define (style-merge base over)
  (style (or (style-fg over) (style-fg base))
         (or (style-bg over) (style-bg base))
         (append (style-attrs base) (style-attrs over))))

(define (face-bytes f)
  (cond
    [(face-stack? f)
     (define styles (filter values (for/list ([l (in-list (face-stack-layers f))]) (face->style l))))
     (if (null? styles) #"" (style-bytes (foldl style-merge (car styles) (cdr styles))))]
    [else (define st (face->style f)) (if st (style-bytes st) #"")]))

(define (attr-bytes attr)
  (cond
    [(and (pair? attr) (eq? (car attr) 'cursor))    (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'selection)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'render))    (face-bytes (cadr attr))]
    [else (face-bytes attr)]))   ; 普通格：attr 就是 face（符号 | #f）
