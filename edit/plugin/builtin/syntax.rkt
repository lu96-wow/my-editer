#lang racket

;;; edit/plugin/builtin/syntax.rkt —— 语法（关键字）高亮插件
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按**语义分组**取色
;;; （face = (palette-color 'keyword 组号)，颜色由主题的 'keyword 色板决定）。
;;; 无状态；open / change 都整篇重扫，产出整篇 fills。跳过正在输入的活动词。

(require racket/string
         "../registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../config/syntax.rkt")

(provide syntax-plugin syntax-spec)

;; 组 → 色板下标
(define category-index
  (for/hash ([c (in-list keyword-category-order)] [i (in-naturals)]) (values c i)))

(define (keyword-face w)
  (palette-color 'keyword (hash-ref category-index (hash-ref keyword-categories w))))

;; 整篇关键字 fills；skip = 活动词 (list line start end) | #f。
(define (syntax-fills text skip)
  (for/list ([tok (in-list (scan-words text))]
             #:when (hash-has-key? keyword-categories (cadddr tok))
             #:unless (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))
    (match-define (list ln s e w) tok)
    (list ln s ln e (keyword-face w))))

(define (syntax-open text _path)
  (values #f (syntax-fills text #f)))

(define (syntax-change _state cctx)
  (values #f (syntax-fills (string-join (vector->list (change-ctx-lines cctx)) "\n")
                           (change-ctx-active cctx))))

(define syntax-plugin
  (doc-plugin 'syntax racket-applies? syntax-open syntax-change))

(define syntax-spec
  (plugin-spec 'syntax (lambda (s) s) (list syntax-plugin)))
