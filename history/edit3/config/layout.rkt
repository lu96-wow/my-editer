#lang racket

;;; edit3/config/layout.rkt —— 布局配置（**纯数据**，不 require 实现）
;;;
;;;   regions        (id side size (member ...) [anchor])   区域；member 是面板 id
;;;                  anchor = root（贴根，跨满整屏）| main（贴主区，让开状态栏，默认）
;;;   enabled-panels (panel-id ...)                装配时创建哪些面板
;;;
;;; 面板 id（tree/buffers/status/input/log）由 core 的面板注册表决定；
;;; 这里只选「用哪些、放哪、多大」。

(provide regions enabled-panels
         border-style borders-on?)

;; 侧栏贴根 → 占满左侧整高；日志贴主区 → 让开底部状态栏。
(define regions
  '((sidebar left   28 (tree buffers) root)
    (log     bottom  6 (log))))

(define enabled-panels
  '(tree buffers status input log))

;; 边框：默认是否给新窗口加，以及用哪个命名 face（调色板见 config/theme.rkt）。
(define borders-on? #t)
(define border-style 'window-border)
