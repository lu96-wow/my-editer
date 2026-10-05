#lang racket

(require "../../core/editor.rkt"
         "../base/layout/main.rkt"
         "../ui/mode.rkt"
         "panes.rkt"
         "edit-panes.rkt"
         "paths.rkt")

;;; lab-rebuild/core/state.rkt —— 应用核心状态（唯一数据源）+ 派生量
;;;
;;; 本层是**功能核心**：只放「数据 + 读 + 改 state 的 setter + 钩子」，
;;; 不放业务动作（在 core/actions/*），也**不认识命令 / 键位 / 插件实现**。
;;;
;;; 不变量集中在这：
;;;   1) 单值 pane 身份在 panes registry；编辑区（可分屏）在 edit-panes；
;;;   2) did ↔ path 只在 path-table；
;;;   3) layout 每帧只算一次（缓存在 app.layout，改动 layout 输入的 setter 会失效它）。
;;;
;;; 改 layout 输入必须走 app-mode-set! / app-left-set! / app-edit-open! /
;;; app-edit-split! / app-edit-remove! / app-size-set!，否则缓存会过期。
;;;
;;; 钩子（hooks）：核心不 require 插件层，但「关文档要清插件状态」这类跨层副作用
;;; 需要一个反向通道。用注册式钩子表达：核心在生命周期点 app-notify!，
;;; 装配层（app/app.rkt）把插件清理注册进来。

(provide (struct-out app)
         app-main-w app-main-h
         app-left-vid app-bottom-vid app-modal-vid
         app-edit-tree app-edit-active
         app-focus-panes app-layout-result app-invalidate-layout!
         app-mode-set! app-left-set! app-sidebar-set! app-edit-open! app-edit-split! app-edit-remove! app-size-set!
         focused-did
         app-hook-add! app-notify!)

(struct app
  (ed                    ; core editor 值
   tree                  ; file-tree 模型
   panes                 ; 单值 pane registry（tree/bufs/state/input）
   edit                  ; 编辑区分屏模型（edit-panes：tree + active）
   bufs                  ; 文档列表面板的展开模型
   left                  ; 左侧显示哪个面板：'tree | 'bufs
   focus                 ; 当前焦点 vid
   mode                  ; #f | prompt | prefix
   cs                    ; command-set（命令层提供，核心只透传）
   paths                 ; did ↔ path 表
   width height
   sidebar-width
   sidebar?              ; 左栏是否显示（#f = 关掉，主区占满整宽）
   layout                ; layout-result 缓存（#f = 失效）
   prev                  ; 上一帧 screen
   quit?
   plugins               ; 插件管理器（核心不解释，交给 plugin/seam）
   hooks)                ; hash 事件名 -> (listof proc)
  #:mutable #:transparent)

(define (app-main-w a)
  (max 1 (- (app-width a) (if (app-sidebar? a) (app-sidebar-width a) 0))))
(define (app-main-h a) (max 1 (- (app-height a) default-statusbar-height)))

;;; ---------- 钩子 ----------

(define (app-hook-add! a name proc)
  (hash-update! (app-hooks a) name (lambda (l) (cons proc l)) '()))

(define (app-notify! a name . args)
  (for ([p (in-list (reverse (hash-ref (app-hooks a) name '())))])
    (apply p args)))

;;; ---------- 编辑区（分屏树） ----------

(define (app-edit-tree a) (edit-panes-tree (app-edit a)))
(define (app-edit-active a) (edit-panes-active (app-edit a)))

;; 把 view 放到 active 编辑窗格（没有窗格就建一个）。会失效 layout。
(define (app-edit-open! a vid)
  (edit-panes-open! (app-edit a) vid)
  (app-invalidate-layout! a))

;; 从编辑区删掉若干 view（关 view / 文档时用）。会失效 layout。
(define (app-edit-remove! a vids)
  (edit-panes-remove! (app-edit a) vids)
  (app-invalidate-layout! a))

;; 拆分 active 编辑窗格，新窗格用 new-vid（view 由 actions 建）。会失效 layout。
(define (app-edit-split! a dir new-vid)
  (edit-panes-split! (app-edit a) dir new-vid)
  (app-invalidate-layout! a))

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
      (let ([lr (compute-layout (app-edit-tree a) (app-width a) (app-height a)
                                #:sidebar? (app-sidebar? a)
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
(define (app-sidebar-set! a flag) (set-app-sidebar?! a flag) (app-invalidate-layout! a))

(define (app-size-set! a w h)
  (set-app-width! a w)
  (set-app-height! a h)
  (app-invalidate-layout! a))
