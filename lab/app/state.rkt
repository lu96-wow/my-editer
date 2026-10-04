#lang racket

(require "../../core/editor.rkt"
         "../base/layout/main.rkt"
         "../ui/mode.rkt"
         "panes.rkt"
         "paths.rkt")

;;; lab/app/state.rkt —— 应用状态（唯一的数据源）+ 派生量
;;;
;;; 只放「数据 + 读」，不放业务动作（那些在 actions.rkt）。三个不变量集中在这：
;;;   1) pane 身份只在 panes registry 一处；
;;;   2) did ↔ path 只在 path-table 一处；
;;;   3) layout 每帧只算一次（缓存在 app.layout，改动 layout 输入的 setter 会失效它）。
;;;
;;; 改 layout 输入必须走 app-mode-set! / app-left-set! / app-edit-vid-set! / app-size-set!，
;;; 否则缓存会过期。

(provide (struct-out app)
         app-main-w app-main-h
         app-left-vid app-bottom-vid app-modal-vid
         app-focus-panes app-layout-result app-invalidate-layout!
         app-mode-set! app-left-set! app-edit-vid-set! app-size-set!
         focused-did)

(struct app
  (ed                    ; core editor 值
   tree                  ; file-tree 模型
   panes                 ; pane registry（vid）
   bufs                  ; 文档列表面板的展开模型
   left                  ; 左侧显示哪个面板：'tree | 'bufs
   focus                 ; 当前焦点 vid
   mode                  ; #f | prompt
   cs                    ; command-set
   paths                 ; did ↔ path 表
   width height
   sidebar-width
   layout                ; layout-result 缓存（#f = 失效）
   prev                  ; 上一帧 screen
   quit?)
  #:mutable #:transparent)

(define (app-main-w a) (max 1 (- (app-width a) (app-sidebar-width a))))
(define (app-main-h a) (max 1 (- (app-height a) default-statusbar-height)))

;;; ---------- pane / 焦点派生 ----------

(define (app-left-vid a) (panes-left (app-panes a) (app-left a)))

(define (app-bottom-vid a)
  (mode-bottom-vid (app-mode a) (panes-state (app-panes a)) (panes-input (app-panes a))))

(define (app-modal-vid a)
  (mode-focus-vid (app-mode a) (panes-input (app-panes a))))

(define (focused-did a)
  (define vid (app-focus a))
  (and vid (editor-view-document-id (app-ed a) vid)))

;; 焦点移动只看主区 + 左栏；底部槽位不参与方向移动。
(define (app-focus-panes a)
  (define b (app-bottom-vid a))
  (for/list ([r (in-list (layout-result-panes (app-layout-result a)))]
             #:unless (eqv? (rectangle-view-id r) b))
    r))

;;; ---------- layout（缓存） ----------

(define (app-layout-result a)
  (or (app-layout a)
      (let* ([p (app-panes a)]
             [ev (panes-edit p)]
             [lr (compute-layout (and ev (leaf ev)) (app-width a) (app-height a)
                                 #:sidebar? #t
                                 #:sidebar-width (app-sidebar-width a)
                                 #:statusbar-height default-statusbar-height
                                 #:left-vid (app-left-vid a)
                                 #:bottom-vid (app-bottom-vid a))])
        (set-app-layout! a lr)
        lr)))

(define (app-invalidate-layout! a) (set-app-layout! a #f))

;;; ---------- 会改 layout 输入的 setter（唯一合法写法） ----------

(define (app-mode-set! a m) (set-app-mode! a m) (app-invalidate-layout! a))
(define (app-left-set! a l) (set-app-left! a l) (app-invalidate-layout! a))

(define (app-edit-vid-set! a v)
  (set-panes-edit! (app-panes a) v)
  (app-invalidate-layout! a))

(define (app-size-set! a w h)
  (set-app-width! a w)
  (set-app-height! a h)
  (app-invalidate-layout! a))
