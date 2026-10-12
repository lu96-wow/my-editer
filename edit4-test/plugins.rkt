#lang racket

;;; edit4-test/plugins.rkt —— 插件契约：catalog / 装配 / hooks / jobs / mode / 两个真实插件
;;;
;;; 覆盖：Environment 的装配 fold、auto-pair（行为）、bracket（decor）、
;;; demo（boot/on-open/hook/doc-key/命令）、async-demo（service + job 钩子）。

(require rackunit racket/list racket/path
         "../edit4/app.rkt" "../edit4/env.rkt" "../edit4/plugin.rkt"
         "../edit4/runtime.rkt" "../edit4/boot.rkt"
         "../edit4/core/world.rkt" "../edit4/core/event.rkt"
         "../edit4/core/command.rkt" "../edit4/core/dispatch.rkt"
         "../edit4/core/hook.rkt" "../edit4/core/job.rkt"
         "../edit4/core/store.rkt" "../edit4/core/mode.rkt"
         "../edit4/content/model.rkt" (except-in "../edit4/content/adapter.rkt" run)
         "../edit4/view/decor.rkt" "../edit4/view/face.rkt"
         "../edit4/decor/bracket-depth.rkt" "../edit4/decor/bracket-match.rkt"
         "../edit4/decor/protocol.rkt"
         "../edit4/plugins/catalog.rkt" "../edit4/config/plugins.rkt"
         "../edit4/plugins/demo.rkt" "../edit4/plugins/async-demo.rkt"
         "../edit4/layout.rkt")

;;; ---------- catalog / 启用 ----------

(check-equal? (map plugin-name (plugins-by-names '(brackets words bracket-match)))
              '(brackets words bracket-match))
(check-exn exn:fail? (lambda () (plugins-by-names '(nope))))

(define env (app-environment))

;;; ---------- auto-pair：命令 + 键表覆盖 ----------

(define (world-with text)
  (define c0 (content-blank))
  (define-values (c1 _did v) (content-add-doc! c0 text 40 3 "t" (string->path "t.rkt")))
  (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)))
(define (world-with-path text path)
  (define c0 (content-blank))
  (define-values (c1 _did v) (content-add-doc! c0 text 40 3 "t" path))
  (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 v)))

(define (send env w ev)
  (define-values (w* _effs)
    (dispatch (environment-commands env) (environment-scopes env)
              (environment-keymap env) (ctx ev (cons 40 3) #f) w))
  w*)
(define (doc-string w)
  (define ed (content-ed (world-content w)))
  (define v (content-vid-of (world-content w) 0))
  (document-string ed (view-did ed v)))
(define (cursor-col w)
  (define ed (content-ed (world-content w)))
  (define v (content-vid-of (world-content w) 0))
  (view-col ed v))

(check-not-false (command-lookup (environment-commands env) 'auto-pair-insert))
(check-equal? (length (environment-decor env)) 4)      ; brackets + word-color + syntax + bracket-match

(define wp (send env (world-with "") (text-event "(")))
(check-equal? (doc-string wp) "()")
(check-equal? (cursor-col wp) 1)
(define wp2 (send env wp (text-event ")")))
(check-equal? (doc-string wp2) "()")
(check-equal? (cursor-col wp2) 2)

;;; ---------- 括号深度 decor ----------

(define wb (world-with "(a (b) c)"))
(define edb (content-ed (world-content wb)))
(define didb (view-did edb (content-vid-of (world-content wb) 0)))
(apply-faces! edb (list bracket-depth-decor) wb)
(check-not-false (document-face-at edb didb 0 0))
(check-not-false (document-face-at edb didb 0 3))

;;; ---------- demo / async-demo：装配后的 Environment ----------

(define denv (install (app-environment) (list demo-plugin async-demo-plugin)))
(check-true (pair? (environment-hooks denv)))
(check-not-false (service-lookup (environment-services denv) 'slow-words))
(check-true (pair? (environment-doc-key-matchers denv)))
(check-equal? (length (environment-boots denv)) 3)      ; completion + docs + demo
(check-equal? (length (environment-on-opens denv)) 1)   ; demo 的 on-open

(define w0 (run-boots denv (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0)))
(check-equal? (store-ref (world-store w0) 'demo-count) 0)

;;; ---------- hooks：after-insert 累计；run-hooks 排空 ----------

(define w1 (run-hooks (environment-hooks denv) (emit! w0 'after-insert (list 0 "x"))))
(check-equal? (store-ref (world-store w1) 'demo-inserts) 1)
(define w2 (run-hooks (environment-hooks denv) (emit! w1 'after-insert (list 0 "y"))))
(check-equal? (store-ref (world-store w2) 'demo-inserts) 2)

;;; ---------- 命令：M-y → demo-bump ----------

(define w3 (car (call-with-values
                 (lambda ()
                   (dispatch (environment-commands denv) (environment-scopes denv)
                             (environment-keymap denv) (ctx (key-event 'y '(alt)) (cons 40 3) #f) w2))
                 cons)))
(check-equal? (store-ref (world-store w3) 'demo-count) 1)

;;; ---------- mode：matcher → 文档键表 ----------

(define demo-km (match-doc-keys (string->path "a.demo") (environment-doc-key-matchers denv)))
(check-true (pair? demo-km))
(check-false (match-doc-keys (string->path "a.rkt") (environment-doc-key-matchers denv)))

;;; ---------- on-open（applies? 门控：只对 *.demo） ----------

(define wo (run-opens denv w0 42 (string->path "x.demo")))
(check-equal? (store-ref (world-store wo) 'demo-opened) "x.demo")
(check-false (store-ref (world-store (run-opens denv w0 42 (string->path "x.rkt"))) 'demo-opened #f))

;;; ---------- jobs / service / job 钩子 ----------

(define-values (wj j) (job-submit w0 'slow-words (hash 'n 3) 'async-demo))
(check-equal? (length (jobs wj)) 1)
(define res (run-service (environment-services denv) j))
(check-equal? res '("async-item-0" "async-item-1" "async-item-2"))
(define wf (job-finish wj (job-id j) res))
(check-equal? (jobs wf) '())
(define wf2 (run-hooks (environment-hooks denv)
                       (emit! wf 'job (list (job-id j) 'slow-words res 'async-demo))))
(check-equal? (store-ref (world-store wf2) 'async-result) res)
(check-false (store-ref (world-store wf2) 'async-loading #f))

;;; ---------- 插件 #:applies?：只对某类文件生效 ----------

;; .rkt：brackets（深度）生效（“a (b)” 的 ( 有深度底色）
(define wrkt (world-with-path "a (b)" (string->path "t.rkt")))
(define edr (content-ed (world-content wrkt)))
(define didr (view-did edr (content-vid-of (world-content wrkt) 0)))
(apply-faces! edr (environment-decor env) wrkt)
(check-not-false (document-face-at edr didr 0 2))

;; .txt：brackets 被 #:applies? 挡住（位置 2 的 ( 无深度底色；光标在 a 上也不触发配对）
(define wtxt (world-with-path "a (b)" (string->path "t.txt")))
(define edt (content-ed (world-content wtxt)))
(define didt (view-did edt (content-vid-of (world-content wtxt) 0)))
(apply-faces! edt (environment-decor env) wtxt)
(check-false (document-face-at edt didt 0 2))

;;; ---------- 端到端：runtime worker → job-event → job 钩子 ----------

(define RSZ (cons 60 10))
(define phase (box 0))
(define (async-backend)
  (backend (lambda () RSZ)
           (lambda ()
             (case (unbox phase)
               [(0) (set-box! phase 1) (key-event 'o '(alt))]        ; M-o 登记 job
               [(1) (sleep 0.4) (set-box! phase 2) (key-event 'q '(ctrl))]  ; 等 worker 回来
               [else (sleep 0.1) (key-event 'q '(ctrl))]))
           (lambda (ps) (void))
           void))

(set-box! phase 0)
(define wend (run (async-backend) denv (boot #:name "*scratch*")))
(check-equal? (store-ref (world-store wend) 'async-result)
              '("async-item-0" "async-item-1" "async-item-2" "async-item-3"))
(check-false (store-ref (world-store wend) 'async-loading #f))

(displayln "edit4/plugins.rkt: all tests passed")
