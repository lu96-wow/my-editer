#lang racket

;;; edit4/view/theme.rkt —— 主题编码：face → ANSI 字节
;;;
;;; 调色板在 config/palette.rkt（数据）；这里把 style → 真彩/256/属性，后端只调 attr-bytes。
;;; piece-attr 形态：(render face) | (cursor . face) | (selection . face) | 普通 face。

(provide face-bytes attr-bytes
         style style-fg style-bg style-attrs theme-ref)

(require (prefix-in t: tui)
         "../config/palette.rkt"
         "face.rkt")

(define (color-bytes fg? c)
  (cond
    [(not c) #""]
    [(and (pair? c) (eq? (car c) 'rgb))
     (if fg? (t:format-rgb-fg-base (cadr c) (caddr c) (cadddr c))
             (t:format-rgb-bg-base (cadr c) (caddr c) (cadddr c)))]
    [(exact-nonnegative-integer? c) (if fg? (t:format-256-fg-base c) (t:format-256-bg-base c))]
    [else #""]))

(define attr-table
  (hash 'bold t:format-bold 'dim t:format-dim 'italic t:format-italic 'underline t:format-underline))

(define (style-bytes st)
  (bytes-append
   (color-bytes #t (style-fg st))
   (color-bytes #f (style-bg st))
   (apply bytes-append (for/list ([a (in-list (style-attrs st))]) (hash-ref attr-table a #"")))))

(define (face->style f)
  (cond
    [(not f) #f]
    [(style? f) f]
    [(symbol? f) (theme-ref f)]
    [(palette-color? f)
     (define cs (palette-ref (palette-color-kind f)))
     (and (pair? cs) (style (list-ref cs (modulo (palette-color-index f) (length cs))) #f '()))]
    [(palette-bg? f)
     (define cs (palette-ref (palette-bg-kind f)))
     (and (pair? cs) (style #f (list-ref cs (modulo (palette-bg-index f) (length cs))) '()))]
    [else #f]))

(define (style-merge base over)
  (style (or (style-fg over) (style-fg base))
         (or (style-bg over) (style-bg base))
         (append (style-attrs base) (style-attrs over))))

(define (face-bytes f)
  (cond
    [(face-stack? f)
     (define styles (filter values (for/list ([l (in-list (face-stack-layers f))]) (face->style l))))
     ;; 层顺序 = 应用顺序（先应用的在前）；style-merge 的 over 后层覆盖前层。
     ;; foldl 回调是 (proc elem acc)，所以写成 (style-merge acc elem)，否则前层反而盖住后层。
     (if (null? styles) #"" (style-bytes (foldl (lambda (elem acc) (style-merge acc elem))
                                                  (car styles) (cdr styles))))]
    [else (define st (face->style f)) (if st (style-bytes st) #"")]))

(define (attr-bytes attr)
  (cond
    [(and (pair? attr) (eq? (car attr) 'cursor)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'selection)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'render)) (face-bytes (cadr attr))]
    [else (face-bytes attr)]))
