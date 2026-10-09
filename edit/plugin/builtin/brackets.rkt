#lang racket

;;; edit/plugin/builtin/brackets.rkt —— 括号按深度背景高亮插件
;;;
;;; open 整篇；change 走 bracket-pair.rkt 的增量（只重建被破坏的一段），但产出**整篇** pair
;;; （kept ++ 重建段），对齐 lab：写回时清空整条 face 再重写，行号平移也不会错。
;;; 产出 face = (palette-bg 'bracket level)；Racket 文件按词法跳过字符串 / 注释里的括号。

(require racket/match
         "bracket-pair.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../registry.rkt")

(provide bracket-plugin bracket-spec)

;; 匹配对区间 → face fills（可跨行）。
(define (pairs->fills pairs)
  (for/list ([f (in-list pairs)])
    (match-define (list ol oc cl cc level) f)
    (list ol oc cl cc (palette-bg 'bracket level))))

(define (br-open text path)
  (define-values (st pairs) (bracket-open text path))
  (values st (pairs->fills pairs)))

(define (br-change st cctx)
  (define-values (st* pairs)
    (bracket-change st (change-ctx-edits cctx) (change-ctx-lines cctx) (change-ctx-path cctx)))
  (values st* (pairs->fills pairs)))

(define bracket-plugin
  (doc-plugin 'brackets racket-applies? br-open br-change))

(define bracket-spec
  (plugin-spec 'brackets (lambda (s) s) (list bracket-plugin)))
