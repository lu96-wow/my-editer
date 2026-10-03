#lang racket

;;; lab/model/view.rkt —— 呈现单元的门面（按 vid）
;;;
;;; 选区 / 视口 / 几何都是 core 或 layout 的现读；这里不做任何缓存。
;;; 显示态写口（选区 / 视口 / 模式）直接转发 core `editor-view-*!`，见 command 层。

(require
 "session.rkt"
 "layout.rkt"
 "../../core/editor.rkt")

(provide
 view-document-id
 view-point
 view-point-line
 view-point-col
 view-selections
 view-primary-range
 view-visible-range
 view-mode
 view-line-numbers?
 view-width
 view-height
 view-rect)

(define (ed s) (session-editor s))

(define (view-document-id s vid) (editor-view-document-id (ed s) vid))
(define (view-point s vid) (editor-view-point (ed s) vid))
(define (view-point-line s vid) (editor-view-point-line (ed s) vid))
(define (view-point-col s vid) (editor-view-point-col (ed s) vid))
(define (view-selections s vid) (editor-view-selections (ed s) vid))
(define (view-primary-range s vid) (editor-view-primary-range (ed s) vid))
(define (view-visible-range s vid) (editor-view-visible-range (ed s) vid))
(define (view-mode s vid) (editor-view-mode (ed s) vid))
(define (view-line-numbers? s vid) (editor-view-line-numbers? (ed s) vid))
(define (view-width s vid) (editor-view-width (ed s) vid))
(define (view-height s vid) (editor-view-height (ed s) vid))

;; 视图当前在布局里的格位；不在布局里 → #f。
(define (view-rect s vid)
  (for/first ([r (in-list (session-rects s))]
              #:when (equal? (pane-rect-id r) vid))
    r))
