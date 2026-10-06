#lang racket

(require "../../core/editor.rkt"
         "../platform/input.rkt"
         "../platform/layout/main.rkt"
         "../platform/slot.rkt"
         "../platform/mode.rkt"
         "../platform/hooks.rkt"
         "../platform/keymap.rkt"
         "../platform/dispatch.rkt"
         "../platform/command.rkt"
         "../platform/state.rkt"
         "../platform/panes.rkt"
         "../platform/panel.rkt"
         "../platform/edit-panes.rkt"
         "../platform/paths.rkt"
         "../platform/package.rkt"
         "../config/defaults.rkt"
         "../config/keys.rkt"
         "../config/packages.rkt"
         "../builtin/edit.rkt"
         "render.rkt")

;;; lab-rebuild/app/app.rkt —— 应用装配 + 事件入口（平台薄壳）
;;;
;;; 唯一的装配点：把 core（编辑器引擎）、platform（状态 / 命令 / 派发 / 模态）、
;;; config（键位 / 默认值 / 包表）、基础编辑包接起来。
;;;
;;; 功能包（文件树 / 列表 / 补全 / 文档 / 高亮 / 自动配对）**不在这里 require**：
;;; 按 config/packages.rkt 的 package 表 dynamic-require 加载（触发顶层注册），
;;; 再调各自的 init 导出。要加 / 撤功能只改配置。
;;; 基础编辑包 builtin/edit.rkt 例外：它提供 app-resize! 等平台动作，直接 require。

(provide app-init app-handle-input app-job-tick!
         ;; 从 render.rkt 重导出：调用方只需 require app/app.rkt
         app-render app-prepare! app-state-refresh! app-bar-panes app-overlay-panes)

;;; ================= 初始化 =================

(define (app-init root width height #:background? [background? #f])
  ;; 0) 按配置加载功能包（触发顶层注册），并让插件 init 能读到后台开关。
  ;;    parameterize 内是 app-init 全程，所以后续 init 也在同一开关下。
  (parameterize ([current-background? background?])
    (for ([entry (in-list package-catalog)]) (load-package! entry))
    (define ed0 (make-blank-editor))                        ; 不预开 *scratch*，开文件才有内容
    ;; 1) 创建所有已注册左栏面板（provider 按注册顺序；后创建的排后面）
    (define-values (ed-panels panels-rev)
      (for/fold ([ed ed0] [ps '()]) ([make (in-list (panel-providers))])
        (define-values (ed2 p) (make (panel-context root ed width height)))
        (values ed2 (cons p ps))))
    (define panels (reverse panels-rev))
    (define sidebar? (pair? panels))
    (define sw default-sidebar-width)
    (define mw (max 1 (- width (if sidebar? sw 0))))
    ;; 2) 底部共享槽位的两份文档
    (define-values (ed1 stdid stvid)
      (editor-add-document-view ed-panels (state->document "") mw 1 "*state*"))
    (define-values (ed2 _indid invid)
      (editor-add-document-view ed1 (input->document (input "" #t)) mw 1 "*input*"))
    (define p (panes stvid invid))
    ;; 3) command-set：global + 每个面板 view 的 per-did 键表
    (define cs0 (command-set-add-doc (command-set (list edit-keys app-keys)) stdid readonly-keys))
    (define cs
      (for/fold ([cs cs0]) ([pn (in-list panels)])
        (command-set-add-doc cs (editor-view-document-id ed2 (panel-vid pn)) (panel-keys pn))))
    ;; 4) 左栏默认显示第一个面板，焦点先落在它上面
    (define left (and sidebar? (panel-name (car panels))))
    (define left-vid (and sidebar? (panel-vid (car panels))))
    (define a (app ed2 p (edit-panes-empty) left-vid #f cs (make-path-table)
                   panels left sw sidebar? width height #f #f #f (make-hash) '()))
    ;; 5) 装配完成后调各面板 init（注册钩子 / 首次刷新）
    (for ([pn (in-list panels)])
      (define init (panel-init pn))
      (when init (init a)))
    ;; 6) 各功能包 init（注册钩子 / 异步源 / 插件）
    (for ([entry (in-list package-catalog)])
      (define init (package-init-proc entry))
      (when init (init a)))
    a))

;;; ================= 事件入口 =================

(define (app-dispatch! a ev)
  (define m (app-mode a))
  (cond
    ;; 独占模态（前缀等）：只看它自己的表，不回落 did / global。
    ;; transient 模态处理完一个事件就退出。
    [(mode-exclusive? m)
     (dispatch-run-direct (mode-tables m) ev a)
     (when (and (eq? (app-mode a) m) (mode-transient? m))
       (app-mode-set! a #f))]
    [else
     (dispatch-run (app-cs a) (focused-did a) (mode-tables m) ev a)]))

(define (app-handle-input a ev)
  (define focus0 (app-focus a))
  (cond
    [(or (null-event? ev) (other-event? ev)) (void)]
    [(resize-event? ev) (app-resize! a (resize-event-cols ev) (resize-event-rows ev))]
    [(mouse-event? ev) (app-handle-mouse a ev)]
    [else (app-dispatch! a ev)])
  ;; 模态：prompt 时焦点一旦离开输入视图 → 取消。
  (when (and (prompt? (app-mode a))
             (not (eqv? (app-focus a) (app-modal-vid a))))
    (app-cancel! a))
  ;; 焦点落在某个编辑窗格 → 它就是 active。
  (define f (app-focus a))
  (when (and f (edit-panes-contains? (app-edit a) f))
    (set-edit-panes-active! (app-edit a) f))
  ;; 焦点变化通知（插件可能要重新取文档上下文）。
  (unless (eqv? focus0 (app-focus a)) (hook-run! a 'focus-changed (app-focus a)))
  ;; 异步结果（可能刚到）→ 让功能包装回。
  (app-job-tick! a)
  ;; post-command：每个事件派发后统一通知（补全过滤 / 状态刷新等）。
  (hook-run! a 'post-command))

(define (app-job-tick! a) (hook-run! a 'job-tick))

;;; ================= 鼠标 =================

(define (app-move-point-to-mouse a rect ev)
  (define vid (rectangle-view-id rect))
  (define-values (line col)
    (editor-view-screen-position->point (app-ed a) vid
                                        (- (mouse-row ev) (rectangle-y rect))
                                        (- (mouse-col ev) (rectangle-x rect))))
  (when line (editor-view-set-point! (app-ed a) vid (point line col))))

(define (app-handle-mouse a ev)
  (define m (app-mode a))
  (cond
    ;; M-m 前缀下点击编辑窗格 → 与 active 互换（只限编辑区），然后退出前缀。
    [(and (pane-move-prefix? m) (eq? (mouse-event-action ev) 'press))
     (app-prefix-end! a)
     (app-move-click! a (mouse-col ev) (mouse-row ev))]
    [else
     (when (prefix? m) (app-prefix-end! a))
     (define p (pane-at (layout-result-panes (app-layout-result a))
                        (mouse-col ev) (mouse-row ev)))
     (cond
       [(prompt? (app-mode a))
        (define input-vid (app-modal-vid a))
        (cond
          [(and p (eqv? (rectangle-view-id p) input-vid))
           (when (eq? (mouse-event-action ev) 'press) (app-move-point-to-mouse a p ev))]
          [(eq? (mouse-event-action ev) 'press) (app-cancel! a)]
          [else (void)])]
       [else
        (when p
          (define vid (rectangle-view-id p))
          (unless (eqv? vid (panes-state (app-panes a)))
            (set-app-focus! a vid)
            (case (mouse-event-action ev)
              [(scroll) (editor-view-scroll! (app-ed a) vid
                                             (if (eq? (mouse-event-button ev) 'up) -1 1))]
              [(press)  (app-move-point-to-mouse a p ev)]
              [else (void)])))])]))
