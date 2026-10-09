#lang racket

;;; edit/plugin/builtin/syntax.rkt —— 语法（关键字）高亮插件
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按**语义分组**取色
;;; （face = (palette-color 'keyword 组号)，颜色由主题的 'keyword 色板决定）。
;;; 无状态；层 = 每行 face 向量（行局部），只重扫脏行。跳过正在输入的活动词。

(require "../registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../core/line-scan.rkt"
         "../../config/syntax.rkt")

(provide syntax-plugin syntax-spec)

;; 组 → 色板下标
(define category-index
  (for/hash ([c (in-list keyword-category-order)] [i (in-naturals)]) (values c i)))

(define (keyword-face w)
  (palette-color 'keyword (hash-ref category-index (hash-ref keyword-categories w))))

;; 行 → face 向量（无关键字 → #f）。active = (list line start end) | #f（跳过它）。
(define (syntax-line active)
  (lambda (line-no line)
    (define n (string-length line))
    (define faces (make-vector n #f))
    (define touched? #f)
    (for ([m (in-list (line-tokens line))])
      (define start (car m))
      (define end (cdr m))
      (define w (substring line start end))
      (define cat (hash-ref keyword-categories w #f))
      (when (and cat
                 (not (and active (= line-no (car active)) (= start (cadr active)))))
        (set! touched? #t)
        (define f (keyword-face w))
        (for ([i (in-range start end)]) (vector-set! faces i f))))
    (and touched? faces)))

(define (syntax-open text _path)
  (values #f (scan-track text (syntax-line #f))))

(define (syntax-change _state layer ctx)
  (define active (face-ctx-active ctx))
  (define dirty (active-dirty ctx))
  (values #f
          (refresh-layer layer (face-ctx-new-text ctx) (dirty-ls dirty) (syntax-line active))
          dirty))

(define syntax-plugin
  (face-plugin 'syntax racket-applies? syntax-open syntax-change))

(define syntax-spec
  (plugin-spec 'syntax (lambda (s) s) (list syntax-plugin)))
