#lang racket

;;; config/layout.rkt —— 布局配置（**纯数据**，不 require 实现）
;;;
;;;   regions        (id side size (member ...) [anchor])   区域；member 是面板 id
;;                  anchor = root（贴根，跨满整屏）| main（贴主区，让开状态栏，默认）
;;;   enabled-panels (panel-id ...)                装配时创建哪些面板
;;;   frame          骨架数据（编辑区 + 状态栏），由 core 解析成 Layout
;;;
;;; 面板 id（tree/buffers/status/input/log）由 core 的面板注册表决定；
;;; 这里只选「用哪些、放哪、多大」。加一个已支持的面板 = 改这里数据。

(provide regions enabled-panels frame
         border-style borders-on?)

;; 侧栏贴根 → 占满左侧整高；日志贴主区 → 让开底部状态栏。
(define regions
  '((sidebar left   28 (tree buffers) root)
    (log     bottom  6 (log))))

(define enabled-panels
  '(tree buffers status input log))

;; 根骨架：主区（区域往这里贴）+ 状态栏（全宽贴底）
;; 状态栏给 2 行：它自身的边框顶边与主区的底边合并（只画一条线），
;; 剩下 1 行内容 + 1 行底边；于是状态栏被包在边框内，而不是悬在边框外。
(define frame
  '(split v
     ((flex (main (pane editor)))
      (2    (pane status)))))

;; 边框：默认是否给新窗口加，以及用哪个命名 face（调色板见 config/theme.rkt，编码见 core/theme.rkt）。
(define borders-on? #t)
(define border-style 'window-border)
