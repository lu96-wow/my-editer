#lang racket

(require racket/file
         "../../../core/editor.rkt"
         "../state.rkt"
         "../paths.rkt")

;;; lab/app/actions/file.rkt —— 文件级动作（保存 / 退出 / 尺寸）

(provide app-save! app-quit! app-resize!)

(define (app-quit! a) (set-app-quit?! a #t))

;; 保存当前焦点 view 对应的文档到它的路径（没有路径 → 不做事）。
(define (app-save! a)
  (define did (focused-did a))
  (define p (and did (path-table-path (app-paths a) did)))
  (when p
    (call-with-output-file p #:exists 'replace
      (lambda (out) (display (editor-document-string (app-ed a) did) out)))))

(define (app-resize! a w h)
  (app-size-set! a (max 20 w) (max 5 h))
  (set-app-prev! a #f))
