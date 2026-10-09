#lang racket

;;; edit/plugin/builtin/brackets.rkt —— 括号按深度背景高亮插件
;;;
;;; 层 = 每行背景向量（bracket-pair.rkt 由行首栈算出）；change 走该模块的增量
;;; （只重建被破坏的 [D,E) 行，其余行由 track 结构共享）。
;;; face = (palette-bg 'bracket level)；Racket 文件按词法跳过字符串 / 注释里的括号。

(require "bracket-pair.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../core/line-scan.rkt"
         "../registry.rkt")

(provide bracket-plugin bracket-spec)

;; 全量：bracket-open* 直接给 (values state layer)。
(define (br-open text path)
  (bracket-open* text path))

(define (br-change st layer ctx)
  (define path (face-ctx-path ctx))
  (define text (face-ctx-new-text ctx))
  (define-values (st* dirty)
    (bracket-change st (face-ctx-changes ctx) text path))
  (define layer*
    (cond
      [(dirty-all? dirty)
       (bracket-layer text (bstate-entries st*) path)]
      [else
       (define entries (bstate-entries st*))
       (define syntax? (racket-file? path))
       (refresh-layer layer text (dirty-ls dirty)
                      (lambda (ln line)
                        (define-values (vec _) (bracket-line line ln (vector-ref entries ln) syntax?))
                        vec))]))
  (values st* layer* dirty))

(define bracket-plugin
  (face-plugin 'brackets racket-applies? br-open br-change))

(define bracket-spec
  (plugin-spec 'brackets (lambda (s) s) (list bracket-plugin)))
