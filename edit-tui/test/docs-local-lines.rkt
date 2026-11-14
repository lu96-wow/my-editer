#lang racket

;;; docs 本地定义保留原始换行 / 缩进，不压成 datum 单行。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../lang/racket/api.rkt"
         "../plugins/docs/api.rkt"
         "../plugins/docs/model.rkt"
         "../edit.rkt")

(define text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (multi x)\n"
                 "  (let ([y x])\n"
                 "    (+ y 1)))\n"))

;; 纯 local-def：原始源码片段。
(define snippet (local-def text 'multi))
(check-equal? snippet
              (string-append "(define (multi x)\n"
                             "  (let ([y x])\n"
                             "    (+ y 1)))"))
(check-true (string-contains? snippet "\n"))

;; docs 面板：本地定义按原文件的行拆开显示。
(define-values (ed state)
  (make-editor-app #:initial-text text
                   #:initial-name "local-lines.rkt"
                   #:initial-resource? #t))
(define docs0 (state-plugin-state state 'docs))
(define-values (_state1 docs1 _actions1)
  (docs-show-name! ed state docs0 "multi"))
(define lines (docs-state-lines docs1))
(check-not-false (member "(define (multi x)" lines))
(check-not-false (member "  (let ([y x])" lines))
(check-not-false (member "    (+ y 1)))" lines))

(displayln "edit-tui/test/docs-local-lines.rkt: ok")
