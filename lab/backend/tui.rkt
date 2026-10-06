#lang racket

(require (prefix-in tui: tui)
         "../../core/editor.rkt"
         "../../core/view/base/screen.rkt"
         "../../core/view/patch.rkt"
         "../app/app.rkt"
         "../app/render.rkt"
         "../builtin/edit.rkt"
         "../config/defaults.rkt"
         "../config/theme/main.rkt"
         "../platform/state.rkt")

;;; lab-rebuild/backend/tui.rkt —— racket-tui 后端
;;;
;;;   racket lab-rebuild/main.rkt [根目录]
;;;
;;; 只做两件事：把 screen patch 变成 ANSI 写出去；读事件喂 app-handle-input。
;;; 每帧先 app-prepare!（刷 state 槽位 + 取窗格），再增量 patch。
;;;
;;; 插件的异步结果源（高亮 / 文档）在 Phase 4 接进来：届时后端只注册统一的
;;; job source，不再单独认识某个功能。

(provide app-draw! app-run)

;;; ================= face → ANSI =================

(define (rgb-fg rgb) (if rgb (apply tui:format-rgb-fg-base rgb) #""))
(define (rgb-bg rgb) (if rgb (apply tui:format-rgb-bg-base rgb) #""))

(define (face-colors face) (theme-face-colors (current-theme) face))
(define (overlay-colors ov) (theme-overlay-colors (current-theme) ov))

(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) tui:format-reverse]
    [else
     (define-values (fg bg) (face-colors face))
     (define-values (ofg obg) (overlay-colors ov))
     (bytes-append (rgb-fg (or ofg fg)) (rgb-bg (or obg bg)))]))

;;; ================= 渲染一帧 =================

(define (app-draw! a)
  (define ed (app-ed a))
  (define w (app-width a))
  (define h (app-height a))
  (define panes (app-prepare! a))           ; 刷新 state 槽位 + 取本帧窗格
  (define decorations (app-overlay-panes a)) ; 分隔线 + 装饰图层
  (define prev (app-prev a))
  (define fresh? (or (not prev)
                     (not (= (screen-width prev) w))
                     (not (= (screen-height prev) h))))
  (editor-set-layout! ed panes)
  (define-values (new render selection)
    (editor-render-layout-patch ed (and (not fresh?) prev) panes (app-focus a) w h decorations))
  (set-app-prev! a new)
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! tui:format-cursor-hide)
  (when fresh? (add! tui:format-screen-clear))
  (for ([p (in-list (append render selection))])
    (add! (bytes-append
           (tui:format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
           (style-bytes (piece-attr p))
           (tui:format-content (piece-text p))
           tui:format-reset)))
  (tui:put-bytes (apply bytes-append (reverse parts)))
  (tui:flush!))

;;; ================= 主循环 =================

(define (app-run root [open-path #f])
  (tui:with-tui
   (lambda ()
     (define-values (rows cols) (tui:get-window-size))
     (define a (app-init root (or cols 80) (or rows 24) #:background? #t))
     (when open-path (app-open-path! a open-path))
     ;; 异步任务结果到达 → 唤醒事件循环：装回 mode + 重绘。
     (for ([src-proc (in-list (app-job-sources a))])
       (define src (src-proc))
       (when src
         (tui:on-source src (lambda (_) (app-job-tick! a) (app-draw! a)))))
     (dynamic-wind
       void
       (lambda ()
         (app-draw! a)
         (let loop ([a a])
           (define ev (tui:read-event))
           (app-handle-input a ev)
           (unless (app-quit? a)
             (app-draw! a)
             (loop a))))
       (lambda () (void))))))
