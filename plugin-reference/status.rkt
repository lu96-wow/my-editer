#lang racket

;;; plugin/status.rkt —— 示例 view 插件：状态行（window -> (listof status-seg)）
;;;
;;; view 插件是「视口投影」，每帧重算，与文档插件（buffer→patch，吃 dirty）不同。
;;; 只 (require "../plugin/api.rkt")。

(require "../plugin/api.rkt")

(provide rowcol-status)

(define (rowcol-status w)
  (define p (window-point w))
  (define line-count (buffer-line-count (window-buffer w)))
  (list
   (status-seg (format "Ln ~a, Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)
   (status-seg "  " #f)
   (status-seg (if (eq? (window-mode w) 'wrap) "wrap" "clip") 'mode)
   (status-seg (format "  ~a 行" line-count) #f)))
