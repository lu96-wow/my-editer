#lang racket

;;; edit-rebuild/core/session/mouse.rkt —— 鼠标（命中 / 点击定位 / 滚轮）
;;;
;;; 局部问题：屏幕坐标命中已落位窗格；点击 = 聚焦 + 定位光标；滚轮 = 滚命中视图（不改焦点）。
;;; 走 adapter 的内核适配，不直接碰 core/editor。

(require "session.rkt"
         "adapter.rkt"
         "focus.rkt"
         "hook.rkt"
         "../geometry/layout.rkt"
         "../focus.rkt")

(provide session-view-at session-mouse-press session-mouse-scroll)

;; 命中的最高窗格（floating 面 deep 大，优先生效）。
(define (session-pane-at s col row)
  (for/last ([p (in-list (session-panes s))]
             #:when (and (>= col (placed-x p)) (< col (+ (placed-x p) (placed-w p)))
                         (>= row (placed-y p)) (< row (+ (placed-y p) (placed-h p)))))
    p))

(define (session-view-at s col row)
  (define p (session-pane-at s col row))
  (and p (placed-vid p)))

(define (session-mouse-press s col row)
  (sync-layout! s)
  (define p (session-pane-at s col row))
  (cond
    [(not p) s]
    [else
     (define vid (placed-vid p))
     (cond
       ;; 浮动面（补全 / 文档窗）不是可聚焦编辑视图：点击不聚焦、不定位。
       [(session-float-vid? s vid) s]
       [else
        (define s1 (session-set-focus s (focus-set (session-focus s) vid)))
        ;; 聚焦可能触发钩子把该视图关掉（如补全菜单）→ 已不在就别再用它的 vid。
        (cond
          [(not (memv vid (session-view-id-list s1))) s1]
          [else
           (define ins (session-pane-inset s1 vid))
           (define-values (line c)
             (session-ed-screen->point s1 vid (- row (+ (placed-y p) ins)) (- col (+ (placed-x p) ins))))
           (define s2 (if line (session-ed-set-point! s1 vid line c) s1))
           (session-run-hooks s2 'after-nav (list vid))])])]))

(define (session-mouse-scroll s col row delta)
  (sync-layout! s)
  (define vid (session-view-at s col row))
  (cond
    [(not vid) s]
    [(session-float-vid? s vid) s]     ; 浮动面不响应滚轮
    [else (session-ed-scroll! s vid delta) s]))
