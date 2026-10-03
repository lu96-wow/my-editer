#lang racket

(require "state.rkt" "../text/document.rkt"
         "../text/base/track.rkt" "../text/base/line.rkt"
         "../text/base/selection.rkt"
         "../view/base/viewport.rkt" "../text/rebase.rkt")

;;; editor/view.rkt —— 视图维护 + 同文档视图传播（就地改 selections/viewport box）
;;;
;;;   view-ensure!          单视图：把主光标滚进视口
;;;   editor-views-rebase!  同文档其它视图：选区过本次变更描述（字面重基准）
;;;   editor-views-clamp!   同文档所有视图：选区夹回合法域（无描述时，如 undo/redo）

(provide view-ensure! editor-views-rebase! editor-views-clamp!)

;; 让视口包含主光标（就地）。
(define (view-ensure! doc v)
  (define p (selection-head (selections-primary (view-selections v))))
  (view-set-viewport! v (viewport-ensure (document-text doc) (view-viewport v) p)))

(define (editor-views-rebase! ed did vid changes)
  (unless (null? changes)
    (for ([x (in-list (editor-views ed))]
          #:when (and (= did (view-did x)) (not (= vid (view-id x)))))
      (view-set-selections! x (selections-rebase changes (view-selections x)))))
  (void))

(define (editor-views-clamp! ed did)
  (define t (document-text (document-entry-document (editor-document-entry ed did))))
  (define n (track-length t))
  (for ([x (in-list (editor-views ed))] #:when (= did (view-did x)))
    (view-set-selections! x (selections-clamp (view-selections x) n (curry track-line-length t))))
  (void))
