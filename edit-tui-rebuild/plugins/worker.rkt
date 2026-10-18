#lang racket

;;; plugins/worker.rkt —— 后台 worker 的入口（**在独立 place / 进程里跑**）
;;;
;;; layer  : plugins
;;; effect : 无（后台纯计算 / 只读查询；不碰 State / core；IO 只读）
;;;
;;; runtime 起 place 时会 `(dynamic-require 'service-run)` 这个模块，然后循环收
;;; `(vector 'job id kind payload)`、算、回 `(vector 'done id result)`。
;;;
;;; 这里就是“一次性后台任务登记”的唯一入口：按 `kind` 分派。
;;; 新增一种后台计算 = 加一条 case + 一个可在 worker 里加载的纯 / 只读模块。
;;;
;;; CONSTRAINT: 以下 payload / 副作用规则不可破（CONSTRAINTS §5）。
;;;   · 本模块不碰 State / core；可以在 worker 进程里做只读的模块 / 文档查询；
;;;   · payload / result 要能跨 place 传递：list / vector / string / symbol /
;;;     number / prefab struct（face 就是 #:prefab）。
;;;
;;; 目前保留的服务（**高亮已不走这里**；语法 / 深度现在是 face-decor）：
;;;   syntax-fills      (vector doc-id text) → (vector doc-id fills)   整篇语法（前景）
;;;   depth-fills       (vector doc-id text) → (vector doc-id fills)   整篇括号深度（背景）
;;;   completion-exports  (list [specs base-dir open]) / '(module-paths) → (listof string)
;;;   doc               (list 'doc name mods) → string | #f
;;;   module-paths      — → (listof string)
;;;
;;; 错误也回 `done`：异常被包成 (vector 'error msg)，父进程照常发 job-done；
;;; 调用方看到非预期 result 时要清 pending / 缓存，不能留 loading。
;;;
;;; 为什么不带版本 token：它是 core 的 document 值，**不可跨 place 传递**。
;;; 过期结果由父进程用 job-id 对账（每个 doc 只认最近一次 job）。
;;;
;;; 跨 place 载荷 / job 对账 / 错误路径的约束见 CONSTRAINTS.md §5。

(provide service-run
         service-kinds)

(require racket/match
         "../model/face-layer.rkt"
         "highlight/lex.rkt"
         "highlight/depth.rkt"
         "lang/pool.rkt"
         "lang/docs.rkt"
         "lang/module-index.rkt")

(define service-kinds
  '(syntax-fills depth-fills completion-exports doc module-paths))

(define (service-run kind payload)
  (case kind
    [(syntax-fills)
     (match-define (vector did text) payload)
     (vector did (syntax-fills-for text))]
    [(depth-fills)
     (match-define (vector did text) payload)
     (vector did (depth-fills-for text))]
    [(completion-exports)
     (match payload
       ['(module-paths) (force module-paths)]
       [(list 'exports base-dir specs open)
        (append* (for/list ([s (in-list specs)]) (spec-names s base-dir open)))]
       [_ '()])]
    [(module-paths) (force module-paths)]
    [(doc)
     (match payload
       [(list 'doc name mods)
        (define d (docs-for name #:modules mods))
        (and d (doc->text d))]
       [_ #f])]
    [else (error 'service-run "未知 service：~a（可用：~a）" kind service-kinds)]))

;;; ════════════════ 两种 fills（都只写自己那一分量） ════════════════

;; 语法：前景（fg）。lex-fills 给的是 core 形状的 fills（值 = face 符号），
;; 这里统一包成 `face-set-fg`，让分层合成知道它只管前景。
(define (syntax-fills-for text)
  (for/list ([f (in-list (lex-fills text))])
    (match-define (list l0 c0 l1 c1 face) f)
    (list l0 c0 l1 c1 (face-set-fg face-empty face))))

;; 括号深度：背景（bg）。每层的深度映射到不同的底色。
(define (depth-fills-for text)
  (for/list ([f (in-list (depth-fills text))])
    (match-define (list l0 c0 l1 c1 face) f)
    (list l0 c0 l1 c1 (face-set-bg face-empty face))))
