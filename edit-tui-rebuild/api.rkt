#lang racket

;;; edit-tui-rebuild/api.rkt —— 统一 API 面
;;;
;;; 只聚合各领域 api.rkt，不 require 实现模块。

(require "base/api.rkt"
         "face/api.rkt"
         "app/api.rkt"
         "filetree/api.rkt"
         "chrome/api.rkt"
         "panel/api.rkt"
         "config/api.rkt"
         "layout/api.rkt"
         "focus/api.rkt"
         "projection/api.rkt"
         "render/api.rkt"
         "command/api.rkt"
         "resource/api.rkt"
         "runtime/api.rkt")

(provide (all-from-out "base/api.rkt"
                       "face/api.rkt"
                       "app/api.rkt"
                       "filetree/api.rkt"
                       "chrome/api.rkt"
                       "panel/api.rkt"
                       "config/api.rkt"
                       "layout/api.rkt"
                       "focus/api.rkt"
                       "projection/api.rkt"
                       "render/api.rkt"
                       "command/api.rkt"
                       "resource/api.rkt"
                       "runtime/api.rkt"))
