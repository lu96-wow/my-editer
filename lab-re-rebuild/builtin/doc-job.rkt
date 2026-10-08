#lang racket

;;; lab-re-rebuild/builtin/doc-job.rkt —— 异步查文档服务 + 查询组合子。
;;;
;;; 三层：
;;;   1) 传输：submit + poll，结果交给内核闸门（e-deliver）。lab-re-rebuild 用 sync runner
;;;      （后端每帧 before-render 轮询）。
;;;   2) 查询上下文（原子）：`view-modules` —— 由纯函数 lang/source 组出当前 view
;;;      的语言服务模块集（complete / docs 共用）。
;;;   3) 版本组合子：`doc-await` —— 把「请求 + 文档句柄闸门」包成一个 effect，
;;;      on-result 由各特性提供（装到自己的 layer 状态）。
;;;
;;; 路径元数据走 document-api（接口），不 require document 实现。

(require racket/match
         racket/path
         "../kernel/api.rkt"
         "document-api.rkt"
         "lang/source.rkt"
         "lang/docs.rkt")

(provide register-doc-job! doc-request! doc-poll!
         view-modules view-modules/context doc-await)

(struct doc-svc (runner-box) #:transparent)

(define (doc-handler req)
  (match-define (list name mods) req)
  (doc->result (docs-for name #:modules mods)))

(define (ensure-runner svc)
  (or (unbox (doc-svc-runner-box svc))
      (let ([r (make-sync-runner doc-handler)])
        (set-box! (doc-svc-runner-box svc) r)
        r)))

(define (doc-request! ctx name mods)
  (define svc (service-ref ctx 'doc-job))
  (runner-submit! (ensure-runner svc) (list name mods)))

;; → (listof effect)：把到齐的结果交给内核闸门（e-deliver）。
(define (doc-poll! ctx)
  (define svc (service-ref ctx 'doc-job))
  (define r (and svc (unbox (doc-svc-runner-box svc))))
  (cond
    [(not r) '()]
    [else
     (for/list ([msg (in-list (runner-poll! r))])
       (e-deliver (car msg) (cdr msg)))]))

(define (doc-job-init ctx)
  (service-put ctx 'doc-job (doc-svc (box #f))))

;;; ================= 查询上下文（原子，complete / docs 共用） =================

;; 当前 view 的模块上下文：严格 = 文件自己的 `#lang` + 顶层 `(require …)`。
;; 都没有（scratch / 无 lang 无 require）→ 以 racket/base 作基线。
(define (view-modules ctx vid)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define text (editor-view-string ed vid))
  (define-values (lang forms) (requires-context text))
  (view-modules/context ctx vid lang forms))

(define (view-modules/context ctx vid lang forms)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define did (editor-view-document-id ed vid))
  (define path (doc-path ctx did))
  (define base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory)))
  (define mods (requires-of-forms lang forms #:base-dir base-dir))
  (if (null? mods) '(racket/base) mods))

;;; ================= 版本组合子（请求 + 文档句柄闸门） =================

;; 登记异步结果闸门：文档句柄未变才交付。
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

;; 轮询是服务自己的事：注册唯一 before-render 钩子（features 不再各挂一个）。
(define (doc-poll-hook ctx _args) (doc-poll! ctx))

(define (register-doc-job! r)
  (for/fold ([r r])
            ([c (in-list
                 (list (contrib 'init 'doc-job doc-job-init)
                       (contrib 'hook 'doc-poll (make-hook 'before-render doc-poll-hook))))])
    (reg-add r c)))
