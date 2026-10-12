#lang racket

;;; edit4/content/files.rkt —— 文件命令（IO 走 effect）
;;;
;;; 命令本身不做 IO：产出 effect，由 runtime 边缘解释（open 会产出新 World）。
;;; reload-tree 也是 effect（读目录在 content/tree.rkt）。

(provide file-commands)

(require "../core/world.rkt" "../core/command.rkt" "../core/effect.rkt"
         "model.rkt" "adapter.rkt")

(define (h-open ctx world args)
  (cons world (list (open-file (car args)))))

(define (h-save ctx world args)
  (define c (world-content world))
  (define id (world-focus world))
  (define v (and c (content-vid-of c id)))
  (define did (and v (content-did-of c v)))
  (define m (and did (content-doc-meta c did)))
  (define path (and m (doc-path m)))
  (cond
    [(not path) #f]
    [else (cons (world-set-content world (doc-save-mark! c did))
                (list (save-file path (document-string (content-ed c) did))))]))

(define (h-reload-tree ctx world args)
  (cons world (list (reload-tree))))

(define file-commands
  (make-command-registry
   (list (cons 'open h-open)
         (cons 'save h-save)
         (cons 'reload-tree h-reload-tree))))
