#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯：text -> state/layer）
;;;
;;; syntax-decor.rkt —— 语法高亮 decor（前景层，增量）
;;;
;;; open   : 整篇扫，得到逐行词法状态 + 每格前景 face
;;; change : 从首个脏行带跨行状态（块注释深度 / 是否在字符串里）重扫到状态收敛
;;;
;;; 适用性由 face-decor 的 applies? 判断（Racket 文件）。层名 = syntax-fg。

(provide syntax-face-decor)

(require racket/path
         "../../model/face-decor.rkt"
         "../../model/face-layer.rkt"
         "../../model/workspace.rkt"
         "lex.rkt")

(define racket-extensions '("rkt" "rktl" "rktd" "scratch"))

(define (racket-path? path)
  (and path
       (let ([e (filename-extension path)])
         (and e (for/or ([ext (in-list racket-extensions)])
                  (string=? ext (string-downcase (bytes->string/utf-8 e))))))))

(define (racket-doc-meta? dm)
  (and dm
       (not (doc-meta-internal? dm))
       (or (eq? (doc-meta-mode dm) 'racket)
           (racket-path? (doc-meta-path dm)))))

;; 词法状态 = (cons block-depth in-string?)，与 lex.rkt 的 lex-line 一致。
(define init-state (cons 0 #f))

;; 把 lex 的 face 符号包装成“只写前景”的 face。
(define (wrap-fg x) (and x (face-set-fg face-empty x)))

(define (scan-line st ln line)
  (define-values (st* vec) (syntax-line st line ln))
  (values st* (for/vector ([x (in-vector vec)]) (wrap-fg x))))

(define (syntax-open _path text)
  (define-values (states layers _st)
    (for/fold ([ss '()] [ls '()] [st init-state])
              ([line (in-list (track->list text))] [ln (in-naturals)])
      (define-values (st* vec) (scan-line st ln line))
      (values (cons st* ss) (cons vec ls) st*)))
  (values (track-of-list (reverse states))
          (track-of-list (reverse layers))))

(define (syntax-change state layer ctx)
  (define changes (face-ctx-changes ctx))
  (cond
    [(null? changes)
     (values state layer (dirty-lines '()))]
    [else
     (define-values (state* layer* dirty)
       (stateful-advance state layer (face-ctx-new-text ctx) changes
                         scan-line init-state))
     (values state* layer* dirty)]))

(define syntax-face-decor
  (face-decor 'syntax 'syntax-fg racket-doc-meta? syntax-open syntax-change))
