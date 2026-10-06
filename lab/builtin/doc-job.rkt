#lang racket

;;; lab-rebuild/builtin/doc-job.rkt —— 异步查文档服务（惰性起 place）+ 查询组合子。
;;;
;;; 三层：
;;;   1) 传输：submit + poll，结果交给内核闸门（e-deliver）。惰性起 runner
;;;      （⚠ place 只能在 with-tui 之后建）；同步后端回落 sync runner。
;;;   2) 查询上下文（原子）：`view-modules` —— 由纯函数 lang/source 组出当前 view
;;;      的语言服务模块集（complete / docs 共用）。
;;;   3) 版本组合子：`doc-await` —— 把「请求 + 文档句柄闸门」包成一个 effect，
;;;      on-result 由各特性提供（装到自己的 layer 状态）。
;;;
;;; 特性只组合这三个出口，不再各自重写「取模块 / 登记闸门 / 轮询」。

(require racket/runtime-path
         racket/match
         racket/path
         "../kernel/editor-api.rkt"
         "../kernel/session.rkt"
         "../kernel/paths.rkt"
         "../kernel/runner.rkt"
         "../kernel/effect.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/hooks.rkt"
         "lang/source.rkt"
         "lang/docs.rkt")

(provide register-doc-job! doc-request! doc-poll!
         view-modules doc-await)

(struct doc-svc (runner-box) #:transparent)

(define-runtime-path doc-worker.rkt "doc-worker.rkt")

(define (doc-handler req)
  (match-define (list name mods) req)
  (doc->result (docs-for name #:modules mods)))

(define (ensure-runner bg? svc)
  (or (unbox (doc-svc-runner-box svc))
      (let ([r (if bg? (make-place-runner doc-worker.rkt 'worker-main 1)
                   (make-sync-runner doc-handler))])
        (set-box! (doc-svc-runner-box svc) r)
        r)))

(define (doc-request! ctx name mods)
  (define svc (service-ref ctx 'doc-job))
  (define bg? (hash-ref (runtime-config (ctx-runtime ctx)) 'background? #f))
  (runner-submit! (ensure-runner bg? svc) (list name mods)))

;; → (listof effect)：把到齐的结果交给内核闸门（e-deliver）。
(define (doc-poll! ctx)
  (define svc (service-ref ctx 'doc-job))
  (define r (and svc (unbox (doc-svc-runner-box svc))))
  (cond
    [(not r) '()]
    [else
     (for/list ([msg (in-list (runner-poll! r))])
       (e-deliver (car msg) (cdr msg)))]))

(define (doc-source svc bg?)
  ((runner-source (ensure-runner bg? svc))))

(define (doc-job-init ctx)
  (define svc (doc-svc (box #f)))
  (define bg? (hash-ref (runtime-config (ctx-runtime ctx)) 'background? #f))
  (define ctx1 (service-put ctx 'doc-job svc))
  (service-add-source ctx1 (lambda () (doc-source svc bg?))))

;;; ================= 查询上下文（原子，complete / docs 共用） =================

;; 语言服务默认模块集：调用方模块 + racket/racket/base。
(define (context-modules mods)
  (remove-duplicates (append mods '(racket racket/base)) equal?))

;; 当前 view 的候选模块：文件目录 + #lang/require 扫出来的模块。
(define (view-modules ctx vid)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define did (editor-view-document-id ed vid))
  (define path (path-table-path (session-paths s) did))
  (define base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory)))
  (define text (editor-view-string ed vid))
  (context-modules (source-requires text #:base-dir base-dir)))

;;; ================= 版本组合子（请求 + 文档句柄闸门） =================

;; 登记异步结果闸门：文档句柄未变才交付。
;; on-result : Ctx result -> (listof effect)。返回 effect（过 after-policy 施加）。
(define (doc-await ctx vid req-id on-result)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define did (editor-view-document-id ed vid))
  (define ver (editor-document-handle ed did))
  (define (current? c v)
    (define ed* (session-editor (ctx-session c)))
    (and (memv did (editor-document-id-list ed*))
         (eq? v (editor-document-handle ed* did))))
  (e-await req-id ver current? on-result))

;;; ================= 注册 =================

;; 轮询是服务自己的事：注册唯一 job-tick 钩子（features 不再各挂一个）。
(define (doc-poll-hook ctx _args) (doc-poll! ctx))

(define (register-doc-job! r)
  (for/fold ([r r])
            ([c (in-list
                 (list (contrib 'init 'doc-job 0 doc-job-init)
                       (contrib 'hook 'doc-poll 0 (make-hook 'job-tick doc-poll-hook))))])
    (reg-add r c)))
