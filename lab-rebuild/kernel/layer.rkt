#lang racket

;;; lab-rebuild/kernel/layer.rkt —— 输入层栈（取代「单一键表」）。
;;;
;;; 模板/实例分离：layer-spec 注册一次（contrib kind 'layer-spec）；
;;; layer-inst 是会话里的一次弹出（带状态）。栈顶在前。
;;; 解析算法在 pipeline.rkt（需要 ctx 才能取注册表）。
;;;
;;; 层用于：前缀键 / 补全菜单 / 文档浮层… 这类**短暂接管输入**的模态。
;;; 与 dock 的区别：dock 是常驻区域，层是临时栈。

(provide (struct-out layer-spec) (struct-out layer-inst) (struct-out layer-stack)
         make-layer stack-empty
         stack-push stack-pop stack-pop-until stack-set
         stack-find stack-top stack-instances)

;; on-enter/on-exit/on-blur : Ctx layer-inst -> (listof effect)
;; tables                   : Ctx layer-inst -> (listof keytable)
;; capture                  : 'all（层表是唯一表）| 'fallthrough（层表优先，落空回 base）
;; focus                    : #f | focus-target（入栈时 focus-push，出栈时 focus-restore）
;; pop                      : 'never（显式出栈）| 'next（下一键后出栈）| 'handled（本层处理则出栈）
(struct layer-spec
  (id on-enter on-exit on-blur tables capture focus pop)
  #:transparent)

(struct layer-inst (spec-id state) #:transparent)
(struct layer-stack (instances) #:transparent)

(define (make-layer id
                    #:on-enter [on-enter (lambda (ctx inst) '())]
                    #:on-exit  [on-exit  (lambda (ctx inst) '())]
                    #:on-blur  [on-blur  #f]
                    #:tables   [tables   (lambda (ctx inst) '())]
                    #:capture  [capture  'fallthrough]
                    #:focus    [focus    #f]
                    #:pop      [pop      'never])
  (layer-spec id on-enter on-exit on-blur tables capture focus pop))

(define (stack-empty) (layer-stack '()))
(define (stack-instances st) (layer-stack-instances st))

(define (stack-push st spec-id state)
  (layer-stack (cons (layer-inst spec-id state) (layer-stack-instances st))))

(define (stack-pop st spec-id)
  (layer-stack (for/list ([i (in-list (layer-stack-instances st))]
                          #:unless (eq? (layer-inst-spec-id i) spec-id))
                 i)))

;; 弹出 spec-id 及其上方所有实例。
(define (stack-pop-until st spec-id)
  (define (drop-until lst)
    (cond [(null? lst) '()]
          [(eq? (layer-inst-spec-id (car lst)) spec-id) (cdr lst)]
          [else (drop-until (cdr lst))]))
  (layer-stack (drop-until (layer-stack-instances st))))

(define (stack-set st spec-id state)
  (layer-stack (for/list ([i (in-list (layer-stack-instances st))])
                 (if (eq? (layer-inst-spec-id i) spec-id) (layer-inst spec-id state) i))))

(define (stack-find st spec-id)
  (for/first ([i (in-list (layer-stack-instances st))]
              #:when (eq? (layer-inst-spec-id i) spec-id)) i))

(define (stack-top st)
  (and (pair? (layer-stack-instances st)) (car (layer-stack-instances st))))
