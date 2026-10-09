#lang racket

;;; edit/plugin/builtin/syntax.rkt —— 语法（关键字）高亮插件
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按 keyword-list 位置取固定色号，
;;; face = (palette-color 'keyword 位置)，颜色由主题的 'keyword 色板决定。
;;; 无状态；open 整篇扫，change 只扫脏行。跳过正在输入的活动词（本次编辑处），
;;; 等词定下来再上色。

(require "../registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../config/syntax.rkt")

(provide syntax-plugin syntax-spec)

(define keyword-index
  (for/hash ([k (in-list keyword-list)] [i (in-naturals)]) (values k i)))

;; 一行里关键字 token 的 fills；skip = 活动词 (list line start end) | #f。
(define (line-fills ln line skip)
  (for/list ([m (in-list (line-tokens line))]
             #:when (hash-has-key? keyword-index (substring line (car m) (cdr m)))
             #:unless (and skip (= ln (car skip)) (= (car m) (cadr skip))))
    (define w (substring line (car m) (cdr m)))
    (list ln (car m) ln (cdr m) (palette-color 'keyword (hash-ref keyword-index w)))))

(define (syntax-open text _path)
  (values #f
          (for/list ([tok (in-list (scan-words text))]
                     #:when (hash-has-key? keyword-index (cadddr tok)))
            (match-define (list ln s e w) tok)
            (list ln s ln e (palette-color 'keyword (hash-ref keyword-index w))))))

(define (syntax-change _state dirty active _path)
  (values #f
          (append* (for/list ([p (in-list dirty)])
                     (line-fills (car p) (cdr p) active)))))

(define syntax-plugin
  (doc-plugin 'syntax racket-applies? syntax-open syntax-change))

(define syntax-spec
  (plugin-spec 'syntax (lambda (s) s) (list syntax-plugin)))
