#lang racket

;;; lab-rebuild/kernel/editor-api.rkt —— lab 唯一 require core 的模块。
;;;
;;; core 固定不动。其余 lab 模块只 require 本模块，不直接碰 core。
;;; 这样 lab 与 core 的耦合收在一个可替换的窄边界里。

(require "../../core/editor.rkt")

(provide (all-from-out "../../core/editor.rkt"))
