#lang racket

;;; edit-tui-rebuild/projection/api.rkt —— 渲染 / 命中投影 API

(require "geometry.rkt")

(provide layout->render-panels
         layout->hit-panels
         layout-content-hit)
