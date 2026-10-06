#lang racket

(require "../../core/editor.rkt"
         "layout/main.rkt"
         "mode.rkt"
         "panes.rkt"
         "panel.rkt"
         "edit-panes.rkt"
         "paths.rkt")

;;; lab-rebuild/platform/state.rkt —— 应用平台状态（唯一数据源）+ 派生量
;;;
;;; 平台核心：只放「数据 + 读 + 改 state 的 setter + 钩子」，
;;; 不放业务动作，也**不认识命令 / 键位 / 插件实现**。
;;;
;;; 不变量集中在这：
;;;   1) 单值 pane 身份在 panes registry；左栏面板在 panels 表；编辑区（可分屏）在 edit-panes；
;;;   2) did ↔ path 只在 path-table；
;;;   3) layout 每帧只算一次（缓存在 app.layout，改动 layout 输入的 setter 会失效它）。
;;;
;;; 改 layout 输入必须走 app-mode-set! / app-left-set! / app-sidebar-set! /
;;; app-edit-open! / app-edit-split! / app-edit-remove! / app-size-set!，否则缓存会过期。
;;;
;;; 钩子（hooks）：平台不 require 插件层；跨层副作用走注册式钩子 ——
;;; 平台在生命周期点 app-notify!，装配层 / 插件把处理器注册进来。

(provide (struct-out app)
         app-main-w app-main-h
         app-left-vid app-bottom-vid app-modal-vid
         app-panel app-panel-names app-internal-vids
         app-edit-tree app-edit-active
         app-focus-panes app-layout-result app-invalidate-layout!
         app-mode-set! app-left-set! app-sidebar-set!
         app-edit-open! app-edit-split! app-edit-remove! app-size-set!
         focused-did
         app-hook-add! app-hook-remove! app-notify! app-hook-first!
         app-job-add-source! app-job-sources
         current-background?)

(struct app
  (ed                    ; core editor 值
   panes                 ; 单值 pane registry（state / input）
   edit                  ; 编辑区分屏模型（edit-panes：tree + active）
   focus                 ; 当前焦点 vid
   mode                  ; #f | prompt | prefix （+ 功能模态）
   cs                    ; command-set（命令层提供，核心只透传）
   paths                 ; did ↔ path 表
   panels                ; (listof panel)  左栏面板（有序）
   left                  ; symbol / #f  左栏显示哪个面板
   sidebar-width
   sidebar?              ; 左栏是否显示
   width height
   layout                ; layout-result 缓存（#f = 失效）
   prev                  ; 上一帧 screen
   quit?
   hooks                 ; hash 事件名 -> (listof proc)
   job-sources)          ; (listof (-> evt? / #f))  异步任务结果源
  #:mutable #:transparent)

;; 主编辑区尺寸：左栏显示时扣掉它，状态栏占底部一条。
(define (app-main-w a)
  (max 1 (- (app-width a) (if (app-sidebar? a) (app-sidebar-width a) 0))))
(define (app-main-h a) (max 1 (- (app-height a) default-statusbar-height)))

;;; ---------- 面板 ----------

(define (app-panel a name)
  (for/first ([p (in-list (app-panels a))] #:when (eq? (panel-name p) name)) p))

(define (app-panel-names a)
  (for/list ([p (in-list (app-panels a))]) (panel-name p)))

;; 左栏此刻该显示的 vid（没有面板 / 左栏关掉 → #f）。
(define (app-left-vid a)
  (and (app-sidebar? a)
       (let* ([name (app-left a)]
              [p (and name (app-panel a name))])
         (and p (panel-vid p)))))

;; 不该出现在「已打开文档」列表里的内部 view：底部槽位 + 所有面板。
(define (app-internal-vids a)
  (append (panes-internal (app-panes a))
          (for/list ([p (in-list (app-panels a))]) (panel-vid p))))

;;; ================= 运行时参数 =================

;; 是否用后台 place worker（装配时由 app-init 设一次；插件 init 读它）。
;; 必须为 #f 时用同步 runner（测试 / 无后台环境）。
(define current-background? (make-parameter #f))

;;; ---------- 钩子 ----------
(define (app-hook-add! a name proc)
  (hash-update! (app-hooks a) name (lambda (l) (append l (list proc))) '()))

(define (app-hook-remove! a name proc)
  (hash-update! (app-hooks a) name (lambda (l) (remove proc l)) '()))

;; 顺序跑完所有 handler；handler 参数 = (app . args)。
(define (app-notify! a name . args)
  (for ([p (in-list (hash-ref (app-hooks a) name '()))])
    (apply p a args)))

;; 顺序跑 handler，返回第一个非 #f 的结果（输入插件「第一个插手的赢」用它）。
(define (app-hook-first! a name . args)
  (for/or ([p (in-list (hash-ref (app-hooks a) name '()))])
    (apply p a args)))

;;; ---------- 异步入队源 ----------

;; 注册一个「结果到达就绪」的源（后端 on-source 注册它）。
(define (app-job-add-source! a source-proc)
  (set-app-job-sources! a (append (app-job-sources a) (list source-proc))))

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

;; 拆分 active 编辑窗格，新窗格用 new-vid（view 由动作层建）。会失效 layout。
(define (app-edit-split! a dir new-vid)
  (edit-panes-split! (app-edit a) dir new-vid)
  (app-invalidate-layout! a))

;;; ---------- pane / 焦点派生 ----------

(define (app-bottom-vid a)
  (mode-bottom-vid (app-mode a) (panes-state (app-panes a)) (panes-input (app-panes a))))

(define (app-modal-vid a)
  (mode-focus-vid (app-mode a) (panes-input (app-panes a))))

(define (focused-did a)
  (define vid (app-focus a))
  (and vid (editor-view-document-id (app-ed a) vid)))

;; 焦点移动看主区 + 左栏；底部槽位不参与方向移动。
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
