#lang racket

;;; edit/session/mouse.rkt —— 鼠标（命中 / 点击定位 / 滚轮）
;;;
;;; 屏幕坐标命中已放置视图；点击 = 聚焦 + 定位光标；滚轮 = 滚命中视图（不改焦点）。
;;; 走 core.rkt 的内核适配，不直接碰 core/editor。

(require "value.rkt"
         "core.rkt"
         "focus.rkt"
         "hook.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt")

(provide session-view-at session-mouse-press session-mouse-scroll)

;; 命中的最高窗格（浮层 deep 大，优先生效）。
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
       ;; 叠加浮层（补全菜单 / 文档窗）不是可聚焦编辑视图：点击不聚焦、不定位。
       ;; （要选中候选需浮层自己处理鼠标；这里至少保证不把它当文档用。）
       [(memv vid (session-overlays s)) s]
       [else
        (define s1 (session-set-focus s (focus-set (session-focus s) vid)))
        ;; 聚焦可能触发钩子把该视图关掉（如补全菜单）→ 已不在就别再用它的 vid。
        (cond
          [(not (memv vid (session-view-id-list s1))) s1]
          [else
           (define-values (line c)
             (session-ed-screen->point s1 vid (- row (placed-y p)) (- col (placed-x p))))
           (define s2 (if line (session-ed-set-point! s1 vid line c) s1))
           ;; 光标定位也算导航：发 'after-nav（补全菜单据此关单）。
           (session-run-hooks s2 'after-nav (list vid))])])]))

(define (session-mouse-scroll s col row delta)
  (sync-layout! s)
  (define vid (session-view-at s col row))
  (cond
    [(not vid) s]
    [(memv vid (session-overlays s)) s]     ; 浮层不响应滚轮
    [else (session-ed-scroll! s vid delta) s]))
