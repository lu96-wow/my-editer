#lang racket

(require "base/screen.rkt" "base/viewport.rkt" "base/layout.rkt"
         "../text/base/selection.rkt" "../text/base/point.rkt"
         "../text/base/track.rkt" "../text/base/width.rkt")

;;; overlay.rkt —— overlay 通道：selections × vrows → cursors / regions
;;;
;;; 与文本通道分开：光标/选区是**视图状态**（来自 selections），不是文档内容。
;;; 全部基于已算好的 **vrows**，不重复派生；列一律是屏幕列（含行号栏偏移）。

(provide
 ;; overlay 通道：selections × vrows → cursors / regions
 overlay-cursors overlay-regions)

;; 每个光标点（selection head）→ screen cursor；不可见的不画。
(define (overlay-cursors t vp vrows sels)
  (filter values
          (for/list ([s (in-list (selections-items sels))] [i (in-naturals)])
            (define-values (r c) (viewport-point->screen-pos/vrows t vp vrows (selection-head s)))
            (and r (cursor r c (= i (selections-primary-index sels)))))))

;; 每个非空选区 → 每条可见屏幕行切一段 region（clip/wrap 通吃：按 vrow 切）。
(define (overlay-regions t vp vrows sels gutter)
  (append*
   (for/list ([s (in-list (selections-items sels))] [i (in-naturals)])
     (define-values (a b) (selection-range s))
     (if (point=? a b)
         '()
         (region-slices t vp vrows a b (= i (selections-primary-index sels)) gutter)))))

(define (region-slices t vp vrows a b primary? gutter)
  (append*
   (for/list ([r (in-range (viewport-height vp))])
     (define vr (vector-ref vrows r))
     (define line (vrow-line vr))
     (cond
       [(or (< line (point-line a)) (> line (point-line b)) (>= line (track-length t))) '()]
       [else
        (define s (track-ref t line))
        (define x (if (= line (point-line a)) (point-col a) 0))
        (define y (if (= line (point-line b)) (point-col b) (string-length s)))
        (define dc0 (index->display-col s x))
        (define dc1 (index->display-col s y))
        (define vs (vrow-start-col vr))
        (define ve (vrow-end-col vr))
        (define c0 (max 0 (- dc0 vs)))
        (define c1 (min (- ve vs) (- dc1 vs)))
        (if (>= c0 c1) '() (list (region r (+ gutter c0) (+ gutter c1) primary?)))]))))
