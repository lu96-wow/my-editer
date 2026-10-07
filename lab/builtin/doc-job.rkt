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
         view-modules view-modules/context doc-await)

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

;; 当前 view 的模块上下文：严格 = 文件自己的 `#lang` + 顶层 `(require …)`。
;; 不再无条件追加 racket / racket/base（否则 `#lang racket/base` 也会命中 racket 的导出，
;; 如 `second`）。都没有（scratch / 无 lang 无 require）→ 以 racket/base 作基线。
(define (view-modules ctx vid)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define text (editor-view-string ed vid))
  (define-values (lang forms) (requires-context text))
  (view-modules/context ctx vid lang forms))

;; 已解析的 (`requires-context`) 版本：调用方已读过 text、解析过 lang/forms，
;; 就不再重复 read 整个文档。
(define (view-modules/context ctx vid lang forms)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define did (editor-view-document-id ed vid))
  (define path (path-table-path (session-paths s) did))
  (define base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory)))
  (define mods (requires-of-forms lang forms #:base-dir base-dir))
  (if (null? mods) '(racket/base) mods))

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
