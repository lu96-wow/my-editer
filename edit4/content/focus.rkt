#lang racket

;;; edit4/content/focus.rkt —— 聚焦主编辑器窗
;;;
;;; 具名导航不集中在这里：面板走 region（activate+focus），文档走 lifecycle 的
;;; show-doc!/show-view!（reveal）。这里只补「聚焦编辑器」这一件（edit3 的 M-e /
;;; focus editor）：焦点仍是窗口 id，编辑器窗 = 第一个非面板窗。

(provide focus-commands)

(require "../core/world.rkt" "../core/command.rkt"
         "model.rkt")

(define (h-focus-editor ctx w args)
  (define id (content-editor-window (world-content w) (world-layout w)))
  (if id (cons (world-set-focus w id) '()) #f))

(define focus-commands
  (make-command-registry
   (list (cons 'focus-editor h-focus-editor))))
