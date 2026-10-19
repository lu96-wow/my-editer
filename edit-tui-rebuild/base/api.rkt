#lang racket

;;; edit-tui-rebuild/base/api.rkt —— 几何值 API

(require "../../core/view/base/rect.rkt")

(provide (struct-out rect)
         rect-right rect-bottom
         rect-inset rect-inset-sides rect-contains?)
