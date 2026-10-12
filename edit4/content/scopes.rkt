#lang racket

;;; edit4/content/scopes.rkt —— 内容层作用域：editor / (panel NAME)
;;;
;;; 作用域是 World 的函数，注册进 Environment（core/scope.rkt 的注册表）。
;;;   editor        聚焦在「可编辑文档」（非面板）上；
;;;   (panel "name") 聚焦在那个面板文档上。
;;; 于是编辑器按键与面板按键互不误触（焦点是树面板时不会往树里打字）。

(provide content-scopes)

(require "../core/world.rkt" "../core/scope.rkt" "../layout.rkt" "model.rkt")

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

;; 焦点是一个浮窗。
(define (float-scope w)
  (and (float-by-id (world-floats w) (world-focus w)) #t))

;; 焦点是该区域的窗口（且区域可见）。
(define (region-scope rid w)
  (define c (world-content w))
  (define r (and c (hash-ref (content-regions c) rid #f)))
  (and r (region-wid r) (eqv? (world-focus w) (region-wid r))))

(define content-scopes
  (make-scope-registry
   (list (cons 'editor editor-scope)
         (cons 'float float-scope)
         (cons (list 'region 'sidebar) (lambda (w) (region-scope 'sidebar w)))
         (cons (list 'panel "*tree*") (lambda (w) (panel-scope "*tree*" w)))
         (cons (list 'panel "*buffers*") (lambda (w) (panel-scope "*buffers*" w)))
         (cons (list 'panel "*input*") (lambda (w) (panel-scope "*input*" w))))))
