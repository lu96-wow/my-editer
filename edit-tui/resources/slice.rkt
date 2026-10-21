#lang racket

;;; edit-tui/resources/slice.rkt —— app-state.store['resource-panel']

(require "../app/state.rkt"
         "model.rkt")

(provide resource-panel-of
         resource-panel-put)

(define (resource-panel-of state)
  (hash-ref (app-state-store state) 'resource-panel (empty-resource-panel)))

(define (resource-panel-put state rp)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'resource-panel rp)]))
