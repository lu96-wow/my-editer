#lang racket

(require "editor-api.rkt")

;;; lab-re-rebuild/kernel/slot-util.rkt —— 版本槽的 fork 工具（特性共用）
;;;
;;; fork-ctx 给的是一次编辑的上下文；插件 / 词表等增量算法都用同一套 edit 约定：
;;;   edit = (list l0 c0 l1 c1 inserted)：编辑前坐标 [l0,c0)-(l1,c1) 替换成 inserted。
;;;   inserted 从**新文本轨**的 change.after 区间取。

(provide fork-ctx->edits track-range-text)

;; 从文本轨取某区间文本。
(define (track-range-text t r)
  (define r* (range-normalize r))
  (define l0 (point-line (range-start r*))) (define c0 (point-column (range-start r*)))
  (define l1 (point-line (range-end r*)))   (define c1 (point-column (range-end r*)))
  (define (row i) (track-ref t i))
  (lines->string
   (cond
     [(= l0 l1) (list (line-slice (row l0) c0 c1))]
     [else (append (list (line-slice (row l0) c0 (line-length (row l0))))
                   (for/list ([i (in-range (add1 l0) l1)]) (row i))
                   (list (line-slice (row l1) 0 c1)))])))

;; fork-ctx → edit 列表（同一编辑前坐标系）。
(define (fork-ctx->edits ctx)
  (define newt (fork-ctx-new-text ctx))
  (for/list ([ch (in-list (fork-ctx-changes ctx))])
    (define b (change-before ch))
    (list (point-line (range-start b)) (point-column (range-start b))
          (point-line (range-end b)) (point-column (range-end b))
          (track-range-text newt (change-after ch)))))
