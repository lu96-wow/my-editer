#lang racket

;;; edit-tui-rebuild/face/api.rkt —— face API

(require "model.rkt")

(provide (struct-out face)
         face-empty
         face-set-fg face-set-bg face-set-attrs
         face-add-attr face-remove-attr face-has-attr?
         compose-face)
