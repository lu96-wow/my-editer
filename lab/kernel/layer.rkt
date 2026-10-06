#lang racket

;;; lab-rebuild/kernel/layer.rkt —— 输入层（取代 mode 单值）。
;;;
;;; 模板/实例分离：layer-spec 注册一次；layer-inst 是会话里的一次弹出（带状态）。
;;; input 是层栈（栈顶在前）。解析算法在 pipeline.rkt（需要 ctx）。

(provide (struct-out layer-spec) (struct-out layer-inst) (struct-out input)
         make-layer input-empty
         input-push input-pop input-pop-until input-replace
         input-find input-top)

;; on-enter/on-exit/on-blur : Ctx layer-inst -> (listof effect)
;; tables                   : Ctx layer-inst -> (listof keytable)
;; capture                  : 'all | 'fallthrough
;; slot                     : #f | 'state | 'input
;; focus                    : #f | focus-target
;; pop                      : 'never | 'next | 'handled
(struct layer-spec
  (id on-enter on-exit on-blur tables capture slot focus pop)
  #:transparent)

(struct layer-inst (spec-id state) #:transparent)
(struct input (instances) #:transparent)

(define (make-layer id
                    #:on-enter [on-enter (λ (ctx inst) '())]
                    #:on-exit  [on-exit  (λ (ctx inst) '())]
                    #:on-blur  [on-blur  #f]
                    #:tables   [tables   (λ (ctx inst) '())]
                    #:capture  [capture  'fallthrough]
                    #:slot     [slot     #f]
                    #:focus    [focus    #f]
                    #:pop      [pop      'never])
  (layer-spec id on-enter on-exit on-blur tables capture slot focus pop))

(define (input-empty) (input '()))

(define (input-push in spec-id state)
  (input (cons (layer-inst spec-id state) (input-instances in))))

(define (input-pop in spec-id)
  (input (for/list ([i (in-list (input-instances in))]
                    #:unless (eq? (layer-inst-spec-id i) spec-id))
           i)))

;; 弹出 spec-id 及其上方所有实例。
(define (input-pop-until in spec-id)
  (define (drop-until lst)
    (cond [(null? lst) '()]
          [(eq? (layer-inst-spec-id (car lst)) spec-id) (cdr lst)]
          [else (drop-until (cdr lst))]))
  (input (drop-until (input-instances in))))

(define (input-replace in spec-id state)
  (input (for/list ([i (in-list (input-instances in))])
           (if (eq? (layer-inst-spec-id i) spec-id) (layer-inst spec-id state) i))))

(define (input-find in spec-id)
  (for/first ([i (in-list (input-instances in))] #:when (eq? (layer-inst-spec-id i) spec-id)) i))

(define (input-top in)
  (and (pair? (input-instances in)) (car (input-instances in))))
