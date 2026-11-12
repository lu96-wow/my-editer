#lang racket

;;; edit-tui-rebuild/features/find/model.rkt —— 当前查找会话（纯值）

(provide (struct-out find-state)
         empty-find-state
         find-state?)

(struct find-state
  (query
   target-vid
   target-version
   matches      ; (listof range)
   index)       ; current match index
  #:transparent)

(define (empty-find-state)
  (find-state "" #f #f '() 0))
