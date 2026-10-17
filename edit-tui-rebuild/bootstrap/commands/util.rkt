#lang racket

;;; layer  : bootstrap/commands
;;; effect : 无（纯 transition 构造器）
;;;
;;; 命令层共用的小工具：
;;;   message / notice-state          往 chrome.message 写一句话
;;;   view-subject                    取 ctx.subject 里的 view-id
;;;   input-busy?                     输入栏是否占用（占用时多数命令拒绝执行）
;;;   frame-area                      终端尺寸 -> core rect
;;;   real-view? / fallback-attached-view
;;;                                   区分“真实文档 view”（非 internal）与切换焦点用的候选
;;;
;;; internal 文档（状态栏 / 输入栏 / 插件面板）不参与保存、不做焦点回退候选。

(provide message
         notice-state
         notice-state-value
         view-subject
         input-busy?
         frame-area
         real-view?
         fallback-attached-view)

(require "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/chrome.rkt"
         "../../dispatch/context.rkt"
         "../../projection/geometry.rkt")

;;; ════════════════ 小工具 ════════════════

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (view-subject ctx)
  (define s (ctx-subject ctx))
  (and (view-id? s) s))

(define (input-busy? ctx) (state-input-active? (ctx-state ctx)))

(define (frame-area state)
  (window-area (state-window state)))

(define (notice-state-value s text)
  (state-chrome* s (λ (c) (chrome-set-message c text))))

(define (notice-state s text)
  (transition-pure (notice-state-value s text)))

;; “真实文档 view” = 不是 infrastructure 文档（状态栏 / 输入栏 / 插件面板）。
;; 这里直接看 doc-meta.internal?，不依赖 document.rkt 的 saveable-doc?（否则循环 require）。
(define (real-view? ws vm)
  (define dm (workspace-doc ws (view-meta-doc vm)))
  (and dm (not (doc-meta-internal? dm))))

(define (fallback-attached-view ws [exclude #f])
  (for/first ([(v vm) (in-hash (workspace-views ws))]
              #:when (and (real-view? ws vm)
                          (workspace-view-attached? ws v)
                          (not (equal? v exclude))))
    v))

;; 把当前 view 从 panel 里拿出来，但保留 view + engine view + document。
