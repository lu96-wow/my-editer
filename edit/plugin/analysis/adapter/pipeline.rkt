#lang racket

;;; edit/plugin/analysis/adapter/pipeline.rkt —— 语法分析流水线（不落槽）
;;;
;;; 流水线只做一件事：**对每个 document 版本，产出一次分析值**，交给 sink。
;;;   · 输入 = 会话里每个 document 的当前版本快照 (path text handle)；
;;;   · 产出 = 异步 worker 算出的 analysis-result（按 handle 标记，只此一次）；
;;;   · sink = (session did handle result -> session)，值怎么用由 sink 决定；
;;;   · 流水线自己只记 pending / 已交付的 handle，**不把值放进 document 槽**。
;;;
;;; 版本语义：
;;;   · 提交时记下 handle；结果回来时 handle 变了 → 丢弃（过期），当前版本下一轮再提交；
;;;   · emitted[did] = 最近交付的 handle，避免同一版本反复提交/交付。
;;;
;;; 分阶段（lex / expand）目前在 worker 里一次做完（analyze）；以后要拆成多阶段，
;;; 只改 request 类型与这里的分派，sink 接口不变。

(require racket/runtime-path
         "../../../session.rkt"
         "../../runner.rkt"
         "../tools/span.rkt")

(provide analysis-pipeline-install analysis-pipeline-step analysis-pipeline-sink)

(define-runtime-path worker-path "../tools/worker.rkt")

;;; ---------- 每会话状态 ----------

(struct p-svc (runner pending emitted) #:transparent)
;; runner  : box（runner | #f）惰性创建（place 需在 tui 之后建）
;; pending : hash did -> handle     已提交、未回来（值为提交时版本）
;; emitted : hash did -> handle     最近交付的版本

(define (ensure-runner svc)
  (or (unbox (p-svc-runner svc))
      (let ([r (make-place-runner worker-path 'worker-main #:wake async-wake)])
        (set-box! (p-svc-runner svc) r)
        r)))

;;; ---------- 装配 ----------

;; 默认 sink：忽略值。
(define (analysis-pipeline-sink s _did _handle _result) s)

(define (analysis-pipeline-install s [sink analysis-pipeline-sink])
  (session-add-hook
   (session-add-hook
    (session-service-put s 'analysis-pipeline (p-svc (box #f) (make-hash) (make-hash)))
    (hook 'before-render (lambda (s _args) (analysis-pipeline-step s sink))))
   (hook 'document-closed
         (lambda (s args)
           (define svc (session-service-ref s 'analysis-pipeline))
           (define did (car args))
           (when svc
             (hash-remove! (p-svc-pending svc) did)
             (hash-remove! (p-svc-emitted svc) did))
           s))))

;;; ---------- 一步 ----------

;; 轮询结果 + 对每个文档确保当前版本已提交；sink 决定值怎么用。
(define (analysis-pipeline-step s sink)
  (define svc (session-service-ref s 'analysis-pipeline))
  (cond
    [(not svc) s]
    [else
     ;; 1) 取回已完成的结果（session-deliver 跑各自 on-result）
     (define s1
       (let ([r (unbox (p-svc-runner svc))])
         (if r
             (for/fold ([s s]) ([m (in-list (runner-poll! r))])
               (session-deliver s (car m) (cdr m)))
             s)))
     ;; 2) 对每个文档确保当前版本已提交
     (for/fold ([s s1]) ([did (in-list (session-document-ids s1))])
       (pipeline-ensure! s svc sink did))]))

;;; ---------- 提交 / 交付 ----------

(define (pipeline-ensure! s svc sink did)
  (define path (session-file-path s did))
  (define handle (session-document-handle s did))
  (cond
    [(not path) s]                                              ; 无路径（面板）跳过
    [(hash-has-key? (p-svc-pending svc) did) s]                 ; 已有在途
    [(eq? handle (hash-ref (p-svc-emitted svc) did #f)) s]      ; 当前版本已交付
    [else
     (define text (session-document-string s did))
     (define id (runner-submit! (ensure-runner svc)
                                (list 'analyze (path->string path) text 0)))
     (hash-set! (p-svc-pending svc) did handle)
     (session-await s id handle
                    ;; current? 恒真：总要回调（清 pending / 判版本都在回调里）
                    (lambda (_s _tok) #t)
                    (lambda (s result)
                      (pipeline-on-result s svc sink did handle result)))]))

(define (pipeline-on-result s svc sink did handle result)
  (hash-remove! (p-svc-pending svc) did)
  (cond
    [(not (memq did (session-document-ids s))) s]               ; 文档已关
    [(not (eq? handle (session-document-handle s did))) s]      ; 过期，丢弃
    [(and (job-result-ok? result) (analysis-result? (job-result-value result)))
     (hash-set! (p-svc-emitted svc) did handle)
     (sink s did handle (job-result-value result))]
    [else (session-log! s (format "analysis: ~a" (job-result-value result)))]))
