#lang racket

;;; edit-tui-rebuild/app/api.rkt —— app 域的对外面（宿主入口用）
;;;
;;; 注意：这是「整个 app 域」的面，包含编排 step。
;;; 插件不能 require 它（step 依赖插件，会成环）；插件只用
;;; app/state.rkt / app/event.rkt / app/action.rkt 这些 app 基础值，
;;; 跨插件组合由 app/step.rkt 负责。

(require "event.rkt"
         "state.rkt"
         "action.rkt"
         "commands.rkt"
         "placement.rkt"
         "step.rkt")

(provide (all-from-out "event.rkt"
                       "state.rkt"
                       "action.rkt"
                       "commands.rkt"
                       "placement.rkt"
                       "step.rkt"))
