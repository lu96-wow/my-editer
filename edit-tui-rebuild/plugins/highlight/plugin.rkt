#lang racket

;;; plugins/highlight/plugin.rkt —— 语法高亮（前景层，后台计算）
;;;
;;; layer  : plugins/highlight
;;; effect : submit-service-effect（把纯计算丢给 worker）+ set-face-layer-effect
;;;
;;; 流程（**非阻塞**）：
;;;
;;;   document-opened / after-edit  → 提交 job（kind = syntax-fills，payload = (doc version text)）
;;;   job-done                      → 版本还对得上就把结果写进自己的 face 层
;;;
;;; 两个关键点：
;;;
;;;   1. **计算在后台**：`submit-service-effect` 交给 runtime 的 worker（独立 place）。
;;;      一个 worker 一条队列 → 多个高亮插件按提交顺序执行，互不插队。
;;;   2. **写的是“一个层”**：`set-face-layer-effect doc 'syntax-fg fills`，
;;;      fills 里每格只带前景分量（`face-set-fg`）。
;;;      另一个插件可以同时写 `'depth-bg` 的背景层，合成见 model/face-layer.rkt。
;;;
;;; 版本对账：worker 回来时文档可能又改了 —— payload 带回 version token，
;;; 不等于当前版本就丢弃这次结果（避免把旧文本的颜色刷上去）。
;;;
;;; 适用范围：只对 Racket 文件（路径后缀 / mode 'racket）生效。

(provide highlight-plugin)

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
         "lex.rkt")

(define service-kind 'syntax-fills)
(define face-layer 'syntax-fg)
(define latest-key 'highlight-latest-job)

;; 每个 doc 最近一次提交的 job-id：结果回来时对账（旧结果丢弃）。
(define (latest-job state did) (hash-ref (plugin-state state latest-key (hash)) did #f))
(define (set-latest-job state did jid)
  (plugin-state* state latest-key (λ (h) (hash-set h did jid)) (hash)))

;;; ════════════════ 适用范围（插件级 applies?） ════════════════

(define racket-extensions '("rkt" "rktl" "rktd" "scratch"))

(define (racket-path? path)
  (and path
       (let ([e (filename-extension path)])
         (and e (for/or ([ext (in-list racket-extensions)])
                  (string=? ext (string-downcase (bytes->string/utf-8 e))))))))

;; doc 是不是 Racket 文件：模式优先（doc-type 可以把它设成 'racket），否则看路径后缀。
(define (racket-doc? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm
       (or (eq? (doc-meta-mode dm) 'racket)
           (racket-path? (doc-meta-path dm)))))

;; 只给“真实文档”上色（面板 / 状态栏 / 输入栏 / 浮层都是 internal）。
(define (highlightable-doc? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm (not (doc-meta-internal? dm)) (racket-doc? state did)))

;;; ════════════════ 提交 / 回收 ════════════════

;; 提交：分配一个 job-id，把 (doc version text) 交给后台。
(define (submit state ev did)
  (cond
    [(not (highlightable-doc? state did)) (transition-pure state)]
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

;; 回收：结果 = (vector did version fills)；版本一致才写层。
(define (apply-result state ev result)
  (define did (vector-ref result 0))
  (define fills (vector-ref result 1))
  (transition state (list (set-face-layer-effect did face-layer fills))))

(define (on-doc state ev args)
  (submit state ev (car args)))

;; job-done：args = (job-id value)；只应用“最近一次提交”的结果（旧结果丢弃）
(define (on-job state ev args)
  (define jid (car args))
  (define result (cadr args))
  (cond
    [(not (and (vector? result) (= 2 (vector-length result)))) (transition-pure state)]
    [else
     (define did (vector-ref result 0))
     (cond
       [(not (equal? jid (latest-job state did))) (transition-pure state)]   ; 过期结果
       [else (apply-result state ev result)])]))

;;; ════════════════ 插件 ════════════════

;; 插件级开关注入：不想要高亮时传 #:enabled? #f（例如“纯文本模式”的 demo）。
(define (highlight-plugin #:enabled? [enabled? #t])
  (make-plugin
   'highlight
   #:env (make-environment
          #:face-layers (list face-layer))
   #:hooks (if enabled?
               (list (make-hook 'document-opened on-doc
                                #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args)))))
                     (make-hook 'after-edit on-doc
                                #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args)))))
                     (make-hook 'job-done on-job))
               '())))
