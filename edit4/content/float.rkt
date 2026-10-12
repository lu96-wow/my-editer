#lang racket

;;; edit4/content/float.rkt —— 浮窗（窗口 + 视图，几何由 anchor 决定）
;;;
;;; 浮窗不进平铺树：World.floats 是 (listof float)，顺序 = z（表头最上）。
;;; 浮窗 id 用**负数**分配，和布局的平铺 id（非负）天然不冲突。
;;;
;;; 命令：float-open（已显示则提到最上）/ float-toggle / float-close / float-cycle / float-raise。
;;; 浮窗也是显示位置：floated 的面板/文档就是同一个 vid 多位置（复用 content.bindings）。

(provide float-commands)

(require racket/list
         "../core/world.rkt" "../core/command.rkt"
         "../layout.rkt"
         "model.rkt" "lifecycle.rkt"
         "../config/floats.rkt")

(define (panel-vid-of w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

(define (float-for-vid w vid)
  (define c (world-content w))
  (for/first ([f (in-list (world-floats w))]
              #:when (eqv? vid (content-vid-of c (float-id f))))
    f))

;; 负 id：与平铺 id 隔离。
(define (fresh-float-id w)
  (define ids (map float-id (world-floats w)))
  (if (null? ids) -1 (sub1 (apply min ids))))

(define (raise-float w id)
  (define f (float-by-id (world-floats w) id))
  (if f
      (world-set-floats w (cons f (filter (lambda (x) (not (eqv? id (float-id x))))
                                          (world-floats w))))
      w))

(define (focus-float w id) (raise-float (world-set-focus w id) id))

(define (open-float w vid name)
  (define c (world-content w))
  (define spec (float-spec name))
  (define id (fresh-float-id w))
  (define a (if spec
                (let ([a (car spec)]) (anchor (car a) (cadr a) (caddr a) (cadddr a) (list-ref a 4)))
                (anchor 'screen 'right 'bottom 2 2)))
  (define sz (if spec (cadr spec) (list 46 10)))
  (define f (float id a (cons (car sz) (cadr sz))))
  (focus-float (world-set-content (world-set-floats w (cons f (world-floats w)))
                                  (content-bind c id vid))
               id))

(define (close-float w id)
  (define c (world-content w))
  (define w1 (world-set-floats w (filter (lambda (f) (not (eqv? id (float-id f)))) (world-floats w))))
  (ensure-focus (world-set-content w1 (content-unbind c id))))

;;; ---------- 命令 ----------

(define (h-float-open ctx w args)
  (define name (car args))
  (define vid (panel-vid-of w (format "*~a*" name)))
  (cond
    [(not vid) #f]
    [else (define f (float-for-vid w vid))
          (cons (if f (focus-float w (float-id f)) (open-float w vid name)) '())]))

(define (h-float-toggle ctx w args)
  (define name (car args))
  (define vid (panel-vid-of w (format "*~a*" name)))
  (cond
    [(not vid) #f]
    [else (define f (float-for-vid w vid))
          (cons (if f (close-float w (float-id f)) (open-float w vid name)) '())]))

(define (h-float-close ctx w args)
  (define id (world-focus w))
  (cond [(and id (float-by-id (world-floats w) id)) (cons (close-float w id) '())]
        [else #f]))

(define (h-float-raise ctx w args)
  (define id (world-focus w))
  (cond [(and id (float-by-id (world-floats w) id)) (cons (raise-float w id) '())]
        [else #f]))

(define (h-float-cycle ctx w args)
  (define fs (world-floats w))
  (cond
    [(or (null? fs) (null? (cdr fs))) #f]
    [else
     (define rotated (append (cdr fs) (list (car fs))))
     (cons (focus-float (world-set-floats w rotated) (float-id (car rotated))) '())]))

(define float-commands
  (make-command-registry
   (list (cons 'float-open h-float-open)
         (cons 'float-toggle h-float-toggle)
         (cons 'float-close h-float-close)
         (cons 'float-raise h-float-raise)
         (cons 'float-cycle h-float-cycle))))
