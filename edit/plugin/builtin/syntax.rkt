#lang racket

;;; edit/plugin/builtin/syntax.rkt —— 语法（关键字）高亮插件
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按 keyword-list 位置取固定色号，
;;; face = (palette-color 'keyword 位置)，颜色由主题的 'keyword 色板决定。
;;; 无状态（run 忽略 state）；跳过正在输入的活动词，等词定下来再上色。

(require "../../plugin/registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../config/syntax.rkt")

(provide syntax-plugin)

(define keyword-index
  (for/hash ([k (in-list keyword-list)] [i (in-naturals)]) (values k i)))

(define (syntax-fills text skip)
  (for/list ([tok (in-list (scan-words text))]
             #:when (hash-has-key? keyword-index (cadddr tok))
             #:unless (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))
    (match-define (list ln s e w) tok)
    (list ln s ln e (palette-color 'keyword (hash-ref keyword-index w)))))

(define (syntax-run _state ctx)
  (define text (doc-ctx-text ctx))
  (values #f (syntax-fills text (active-token (scan-words text) (doc-ctx-point ctx)))))

(define syntax-plugin
  (doc-plugin 'syntax racket-applies? syntax-run))
