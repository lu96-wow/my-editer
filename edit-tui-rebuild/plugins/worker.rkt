#lang racket

;;; plugins/worker.rkt —— 后台 worker 的入口（**在独立 place / 进程里跑**）
;;;
;;; layer  : plugins
;;; effect : 无（纯计算；不 require 任何 core / 状态 / IO 模块）
;;;
;;; runtime 起 place 时会 `(dynamic-require 'service-run)` 这个模块，然后循环收
;;; `(vector 'job id kind payload)`、算、回 `(vector 'done id result)`。
;;;
;;; 这里就是“插件把纯计算登记到后台”的唯一入口：按 `kind` 分派。
;;; 新增一种后台计算 = 加一条 case + 一个纯函数模块。
;;;
;;; 约束（重要）：
;;;   · 本模块与它 require 的模块必须是**纯**的（不碰 State / core / 文件）；
;;;   · payload / result 要能跨 place 传递：list / vector / string / symbol /
;;;     number / prefab struct（face 就是 #:prefab）。
;;;
;;; 目前的服务：
;;;   syntax-fills  (vector doc-id text) → (vector doc-id fills)   语法（前景）
;;;   depth-fills   (vector doc-id text) → (vector doc-id fills)   括号深度（背景）
;;;
;;; 为什么不带版本 token：它是 core 的 document 值，**不可跨 place 传递**。
;;; 过期结果由父进程用 job-id 对账（每个 doc 只认最近一次 job）。

(provide service-run
         service-kinds)

(require "../model/face-layer.rkt"
         "highlight/lex.rkt"
         "highlight/depth.rkt")

(define service-kinds '(syntax-fills depth-fills))

(define (service-run kind payload)
  (case kind
    [(syntax-fills)
     (match-define (vector did text) payload)
     (vector did (syntax-fills-for text))]
    [(depth-fills)
     (match-define (vector did text) payload)
     (vector did (depth-fills-for text))]
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
