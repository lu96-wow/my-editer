#lang racket

;;; command/main.rkt —— 命令层入口
;;;
;;; 纯的部分：key / keymap（可单测，不 require tui）；
;;; 接 tui 的部分：event->key / key-reader。
;;; require 本模块即得到全部能力。

(require "key.rkt"
         "keymap.rkt"
         "tui.rkt")

(provide (all-from-out "key.rkt"
                       "keymap.rkt"
                       "tui.rkt"))
