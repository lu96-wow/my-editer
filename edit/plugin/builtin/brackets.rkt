#lang racket

;;; edit/plugin/builtin/brackets.rkt —— 括号按深度背景高亮插件
;;;
;;; open 整篇；change 走 bracket-pair.rkt 的增量（只重建被破坏的一段）。
;;; 产出 face = (palette-bg 'bracket level)，颜色由主题的 'bracket 背景调色板决定。
;;; Racket 文件额外按词法跳过字符串 / 行注释 / 块注释 / 字符字面量里的括号。

(require racket/match
         "bracket-pair.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../registry.rkt")

(provide bracket-plugin bracket-spec)

;; 把匹配对区间（可能跨行）裁剪成**单行** fills（协议要求 l0 = l1）；
;; 只保留 touched 行。lines 用于取行末列（多行对在该行的范围到行末）。
(define (pairs->line-fills pairs lines touched)
  (define tset (make-hash))
  (for ([l (in-list touched)]) (hash-set! tset l #t))
  (append*
   (for/list ([f (in-list pairs)])
     (match-define (list ol oc cl cc level) f)
     (for/list ([ln (in-range ol (add1 cl))]
                #:when (and (hash-ref tset ln #f) (< ln (vector-length lines))))
       (define len (string-length (vector-ref lines ln)))
       (define a (if (= ln ol) oc 0))
       (define b (if (= ln cl) cc len))
       (if (<= a b) (list ln a ln b (palette-bg 'bracket level)) '())))))

(define (all-lines lines) (for/list ([i (in-range (vector-length lines))]) i))

(define (ctx->lines cctx)
  (define n (change-ctx-line-count cctx))
  (define ref (change-ctx-line-ref cctx))
  (list->vector (for/list ([i (in-range n)]) (ref i))))

(define (br-open text path)
  (define-values (st pairs) (bracket-open text path))
  (values st (pairs->line-fills pairs (bstate-lines st) (all-lines (bstate-lines st)))))

(define (br-change st cctx)
  (define lines (ctx->lines cctx))
  (define-values (st* touched pairs) (bracket-change st (change-ctx-edits cctx) lines (change-ctx-path cctx)))
  (values st* touched (pairs->line-fills pairs lines touched)))

(define bracket-plugin
  (doc-plugin 'brackets racket-applies? br-open br-change))

(define bracket-spec
  (plugin-spec 'brackets (lambda (s) s) (list bracket-plugin)))
