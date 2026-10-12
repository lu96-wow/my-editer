#lang racket

;;; edit4/content/scopes.rkt —— 内容层作用域：editor / (panel NAME)
;;;
;;; 作用域是 World 的函数，注册进 Environment（core/scope.rkt 的注册表）。
;;;   editor        聚焦在「可编辑文档」（非面板）上；
;;;   (panel "name") 聚焦在那个面板文档上。
;;; 于是编辑器按键与面板按键互不误触（焦点是树面板时不会往树里打字）。

(provide content-scopes)

(require "../core/world.rkt" "../core/scope.rkt" "model.rkt")

(define (focused-vid w)
  (define c (world-content w))
  (and c (content-vid-of c (world-focus w))))

(define (editor-scope w)
  (define c (world-content w))
  (define v (focused-vid w))
  (and v (not (content-panel? c v))))

(define (panel-scope name w)
  (define c (world-content w))
  (define v (focused-vid w))
  (and v (eqv? v (content-panel-vid c name))))

(define content-scopes
  (make-scope-registry
   (list (cons 'editor editor-scope)
         (cons (list 'panel "*tree*") (lambda (w) (panel-scope "*tree*" w)))
         (cons (list 'panel "*buffers*") (lambda (w) (panel-scope "*buffers*" w)))
         (cons (list 'panel "*input*") (lambda (w) (panel-scope "*input*" w))))))
