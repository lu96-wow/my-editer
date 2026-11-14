#lang racket

;;; edit-tui/editor/engine/viewport-write.rkt —— 通用 viewport 写能力
;;;
;;; viewport 是 view 属性，不属于某个文档种类；行列同步只改视口锚点，
;;; 不改文本 / history / changes。

(require "../../../core/editor.rkt"
         "store.rkt")

(provide engine-set-view-anchor-point!)

(define (engine-set-view-anchor-point! e vid p)
  (define v (engine-view-object e vid))
  (when v
    (view-scroll-to-point! v p))
  (void))
