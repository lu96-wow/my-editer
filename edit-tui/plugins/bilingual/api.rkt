#lang racket

;;; edit-tui/plugins/bilingual/api.rkt —— host 调用的插件状态面
;;;
;;; host 只通过这里 bind / unbind / 读取 pair；不直接写插件内部状态。
;;; plugin-state 的最终写回仍由 host 用 state-set-plugin-state 完成。

(require "../../editor/api.rkt"
         "model.rkt"
         "translate.rkt")

(provide empty-bilingual-state
         bilingual-state?
         pair-source-doc-id
         pair-mirror-doc-id
         pair-mirror-view-id
         pair-translator-id
         bilingual-default-translator-id
         bilingual-translator
         bilingual-pair-for-source
         bilingual-pair-for-mirror
         bilingual-bind!
         bilingual-unbind!)

(define (empty-bilingual-state)
  (make-bilingual-state
   (hash default-translator-id default-translator)
   default-translator-id))

(define (bilingual-default-translator-id ps)
  (if (bilingual-state? ps)
      (bilingual-state-default-translator-id ps)
      default-translator-id))

(define (bilingual-translator ps id)
  (and (bilingual-state? ps)
       (state-translator ps id)))

(define (bilingual-pair-for-source ps did)
  (pair-for-source ps did))

(define (bilingual-pair-for-mirror ps did)
  (pair-for-mirror ps did))

;; source-lines / mirror-lines 先从空开始；下一次 sync 会整篇投影。
(define (bilingual-bind! state ps source-doc-id mirror-doc-id mirror-view-id
                         requested-translator-id)
  (cond
    [(not (bilingual-state? ps)) (values state ps)]
    [else
     (define tr (or (bilingual-translator ps requested-translator-id)
                    (bilingual-translator ps
                                          (bilingual-default-translator-id ps))
                    default-translator))
     (define p
       (pair source-doc-id mirror-doc-id mirror-view-id
             (translator-id tr) (translator-version tr)
             #f #f '() '()))
     (values state (state-set-pair ps p))]))

(define (bilingual-unbind! state ps source-doc-id)
  (cond
    [(not (bilingual-state? ps)) (values state ps)]
    [else (values state (state-remove-pair ps source-doc-id))]))
