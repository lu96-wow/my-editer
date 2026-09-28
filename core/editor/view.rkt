#lang racket

(require "state.rkt" "write.rkt"
         "../text/document.rkt"
         "../text/base/selection.rkt" "../text/base/track.rkt"
         "../text/base/line.rkt" "../text/rebase.rkt"
         "../view/base/viewport.rkt")

;;; editor/view.rkt —— editor 层的视图维护
;;;
;;; 文档变更后把「视图」重新对齐到新文档：
;;;     view-ensure          单视图：把主光标滚进视口
;;;     editor-views-rebase  同文档**其它**视图：选区过本次变更描述（字面重基准）
;;;     editor-views-clamp   同文档**所有**视图：选区夹回合法域（无描述时，如 undo/redo）
;;;
;;; 三者都只动 view（选区分量 / 视口），**不动 document**；document 由调用方换。
;;; 落地走 write.rkt 的低层写口（editor-set-view），命令层不直接碰。

(provide
 ;; ---------- 单视图 ----------
 view-ensure

 ;; ---------- 同文档视图传播 ----------
 editor-views-rebase
 editor-views-clamp)

;;; ---------- 单视图 ----------

;; 让视口包含主光标。
(define (view-ensure doc v)
  (define p (selection-head (selections-primary (view-selections v))))
  (struct-copy view v [viewport (viewport-ensure (document-text doc) (view-viewport v) p)]))

;;; ---------- 同文档视图传播 ----------

;; 其它视图：旧选区过本次变更描述（字面重基准；不动视口也不动文档）。
(define (editor-views-rebase ed did vid changes)
  (if (null? changes)
      ed
      (for/fold ([e ed]) ([x (in-list (editor-views ed))]
                          #:when (and (= did (view-did x)) (not (= vid (view-id x)))))
        (editor-set-view e (struct-copy view x
                            [selections (selections-rebase changes (view-selections x))])))))

;; 同文档所有视图：选区夹回新文档合法域（无变更描述时用，如 undo/redo，先保不崩）。
(define (editor-views-clamp ed did)
  (define t (document-text (document-entry-document (editor-document-entry ed did))))
  (define n (track-length t))
  (define (line-len l) (line-length (track-ref t l)))
  (for/fold ([e ed]) ([x (in-list (editor-views ed))] #:when (= did (view-did x)))
    (editor-set-view e (struct-copy view x
                        [selections (selections-clamp (view-selections x) n line-len)]))))
