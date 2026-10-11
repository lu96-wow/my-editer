#lang racket

;;; edit-rebuild/core/session/surfaces.rkt —— 面登记（纯）
;;;
;;; 局部问题：会话里有哪些「面」（dock / float）。浮面 vid 由 items 派生，不再单独记账。
;;; 面值本体在 surface/surface.rkt；这里只做登记与查询。

(require "../surface/surface.rkt")

(provide (struct-out surfaces)
         surfaces-new
         surfaces-add surfaces-remove surfaces-ref surfaces-for-vid
         surfaces-floats)

(struct surfaces (items) #:transparent)
;; items : (listof surface)   已注册的面

(define (surfaces-new) (surfaces '()))

(define (surfaces-add s sf)
  (struct-copy surfaces s [items (append (surfaces-items s) (list sf))]))

(define (surfaces-remove s id)
  (struct-copy surfaces s
    [items (for/list ([sf (in-list (surfaces-items s))]
                      #:unless (eq? id (surface-id sf))) sf)]))

(define (surfaces-ref s id)
  (for/first ([sf (in-list (surfaces-items s))] #:when (eq? id (surface-id sf))) sf))

(define (surfaces-for-vid s vid)
  (for/first ([sf (in-list (surfaces-items s))] #:when (eqv? vid (surface-vid sf))) sf))

;; 浮面 vid（dock 语义 / 不进缓冲区）——从面值派生，无需单独维护书签。
(define (surfaces-floats s)
  (for/list ([sf (in-list (surfaces-items s))] #:when (surface-float? sf))
    (surface-vid sf)))
