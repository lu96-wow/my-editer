#lang racket

;;; lab-rebuild/kernel/panel.rkt —— 左栏面板机制（role 窗格 + contribution）。
;;;
;;; 面板只描述「怎么建视图 / 自己的键 / 每帧怎么刷新」；放在哪个区域由 frame 的 role 决定。
;;; 平台不认识具体面板。

(provide (struct-out panel-spec) (struct-out panel)
         panel-name panel-vid)

(struct panel-spec (name priority make keys refresh) #:transparent)
;; make    : (ed w h) -> (values ed vid data)
;; keys    : (listof keytable)   该面板视图的 per-did 键表
;; refresh : (ctx vid data) -> (listof effect)

(struct panel (pspec view data) #:transparent)

(define (panel-name p) (panel-spec-name (panel-pspec p)))
(define (panel-vid p) (panel-view p))
