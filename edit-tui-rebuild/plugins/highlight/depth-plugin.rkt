#lang racket

;;; plugins/highlight/depth-plugin.rkt —— 括号深度底色（背景层，后台计算）
;;;
;;; layer  : plugins/highlight
;;; effect : submit-service-effect（kind = depth-fills）+ set-face-layer-effect
;;;
;;; 它与 `plugins/highlight/plugin.rkt`（前景层）**互不覆盖**：
;;;
;;;   highlight 写 'syntax-fg（每格只带 fg）
;;;   depth     写 'depth-bg （每格只带 bg）
;;;
;;; 两个 job 提交给**同一个 worker**（一个 place = 一条队列），按顺序执行；
;;; 结果各写各的层，合成由 `model/face-layer.rkt` 按 `env.face-layers` 的层序做。
;;; 所以同一格上能看到“关键字前景 + 深度背景”。

(provide depth-bg-plugin)

(require racket/path
         "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../effects/engine.rkt"
         "../../env/environment.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "depth.rkt")

(define service-kind 'depth-fills)
(define face-layer 'depth-bg)
(define latest-key 'depth-latest-job)

(define (latest-job state did) (hash-ref (plugin-state state latest-key (hash)) did #f))
(define (set-latest-job state did jid)
  (plugin-state* state latest-key (λ (h) (hash-set h did jid)) (hash)))

(define racket-extensions '("rkt" "rktl" "rktd" "scratch"))

(define (racket-path? path)
  (and path
       (let ([e (filename-extension path)])
         (and e (for/or ([ext (in-list racket-extensions)])
                  (string=? ext (string-downcase (bytes->string/utf-8 e))))))))

(define (racket-doc? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm
       (or (eq? (doc-meta-mode dm) 'racket)
           (racket-path? (doc-meta-path dm)))))

(define (eligible? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm (not (doc-meta-internal? dm)) (racket-doc? state did)))

;;; ════════════════ 提交 / 回收 ════════════════

(define (submit state ev did)
  (cond
    [(not (eligible? state did)) (transition-pure state)]
    [else
     (define version (engine-view-doc-version ev did))
     (define text (engine-view-doc-text ev did))
     (cond
       [(not (and version text)) (transition-pure state)]
       [else
        (define-values (job-id s1) (state-next-id state 'job))
        (transition (set-latest-job s1 did job-id)
                    (list (submit-service-effect
                           job-id service-kind
                           (vector did text))))])]))

(define (apply-result state ev result)
  (define did (vector-ref result 0))
  (define fills (vector-ref result 1))
  (transition state (list (set-face-layer-effect did face-layer fills))))

(define (on-doc state ev args) (submit state ev (car args)))

;; job-done：只应用“最近一次提交”的结果（旧结果丢弃）
(define (on-job state ev args)
  (define jid (car args))
  (define result (cadr args))
  (cond
    [(not (and (vector? result) (= 2 (vector-length result)))) (transition-pure state)]
    [else
     (define did (vector-ref result 0))
     (cond
       [(not (equal? jid (latest-job state did))) (transition-pure state)]
       [else (apply-result state ev result)])]))

;;; ════════════════ 插件 ════════════════

(define (depth-bg-plugin)
  (make-plugin
   'depth-bg
   #:env (make-environment
          #:face-layers (list face-layer))
   #:hooks (list (make-hook 'document-opened on-doc
                            #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args)))))
                 (make-hook 'after-edit on-doc
                            #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args)))))
                 (make-hook 'job-done on-job))))
