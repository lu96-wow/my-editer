#lang racket

;;; edit-tui-rebuild/focus/api.rkt —— 焦点导航 API

(require "model.rkt")

(provide layout-panel-focusable?
         layout-focusable-panels
         layout-focus-panel-at
         layout-focus-neighbor)
