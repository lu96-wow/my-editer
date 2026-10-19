#lang racket

;;; edit-tui-rebuild/api/geometry.rkt —— 渲染 / 命中投影 API

(require "../projection/geometry.rkt")

(provide layout->render-panels
         layout->hit-panels)
