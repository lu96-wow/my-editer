#lang racket

;;; edit2/theme.rkt —— 命名样式表（face 名字 → 真彩色 / 256 色）
;;;
;;; 编辑器里所有样式都用**命名 face**（符号）：'window-border、'status、'tree-dir …。
;;; 本模块把名字映射到具体颜色 + 属性，再翻成 ANSI 字节；后端只调 attr-bytes。
;;;
;;; core 的 piece-attr 形态：
;;;   (render face)      普通文本格，face = 名字（符号）| #f
;;;   (cursor . face)    光标格
;;;   (selection . face) 选区格

(provide style style-fg style-bg style-attrs
         face-bytes attr-bytes
         theme-ref)

(require (prefix-in t: tui))

;;; ---------- 样式值 ----------

(struct style (fg bg attrs) #:transparent)
;; fg / bg : #f（终端默认）| (rgb r g b) 真彩色 | 0..255 的整数（256 色）
;; attrs   : (listof 'bold | 'dim | 'italic | 'underline)

(define (rgb r g b) (list 'rgb r g b))

;; 命名样式表：名字 → style。加一个样式 = 这里加一行。
(define palette
  (hash
   'default        (style #f #f '())
   'dim            (style (rgb 128 128 138) #f '())
   'bold           (style #f #f '(bold))
   'italic         (style #f #f '(italic))
   'underline      (style #f #f '(underline))
   'accent         (style (rgb 122 180 255) #f '(bold))
   ;; 窗口 / 面板
   'window-border  (style (rgb 105 112 128) #f '())
   'window-focus   (style (rgb 160 190 255) #f '())
   'status         (style (rgb 210 214 224) (rgb 40 42 54) '())
   'status-accent  (style (rgb 255 220 150) (rgb 40 42 54) '(bold))
   ;; 资源面板
   'tree-dir       (style (rgb 122 180 255) #f '(bold))
   'tree-file      (style (rgb 190 190 200) #f '())
   'tree-cursor    (style (rgb 255 220 150) #f '(bold))
   'buffers-doc    (style (rgb 210 214 224) #f '(bold))
   'buffers-view   (style (rgb 150 200 150) #f '())
   'log            (style (rgb 180 180 180) #f '())))

(define (theme-ref name) (hash-ref palette name #f))

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

(define (face-bytes f)
  (cond
    [(not f) #""]
    [(style? f) (style-bytes f)]
    [(symbol? f) (define st (theme-ref f)) (if st (style-bytes st) #"")]
    [else #""]))

(define (attr-bytes attr)
  (cond
    [(and (pair? attr) (eq? (car attr) 'cursor))    (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'selection)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'render))    (face-bytes (cadr attr))]
    [else #""]))
