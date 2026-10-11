#lang racket

;;; edit-rebuild/core/theme/scheme.rkt —— 配色方案结构（纯）
;;;
;;; 一套方案 = 正文色 + keyword 分组色板（顺序见插件的语法分组配置）
;;; + 词色板 + 括号底 4 层。具体方案在 theme/schemes/*.rkt，
;;; 选哪套由 config/theme.rkt 的 require 决定（只加载一套）。

(provide (struct-out scheme))

(struct scheme (fg keyword word bracket) #:transparent)
;; fg      : rgb               正文
;; keyword : (vectorof rgb)    def / control / macro / binding / module
;; word    : (vectorof rgb)
;; bracket : (vectorof rgb)    4 层背景
