#lang racket

;;; lab-rebuild/kernel/panel.rkt —— 左栏面板机制（role 窗格 + contribution）。
;;;
;;; 面板只描述「怎么建视图 / 自己的键 / 每帧怎么刷新」；放在哪个区域由 frame 的 role 决定。
;;; 平台不认识具体面板。

(provide (struct-out panel-spec) (struct-out panel)
         panel-name panel-vid shown-panel)

(struct panel-spec (name priority make keys refresh) #:transparent)
;; make    : (root ed w h) -> (values ed vid data)
;; keys    : (listof keytable)   该面板视图的 per-did 键表
;; refresh : (ctx vid data) -> (listof effect)

(struct panel (pspec view data) #:transparent)

(define (panel-name p) (panel-spec-name (panel-pspec p)))
(define (panel-vid p) (panel-view p))

;; 当前显示的面板：active-panel 命中的那个，否则第一个（无 → #f）。
;; layout 与 focus 几何共用同一选择，避免"显示的"与"导航的"不一致。
(define (shown-panel panels active)
  (or (for/first ([p (in-list panels)] #:when (eq? (panel-name p) active)) p)
      (and (pair? panels) (car panels))))
