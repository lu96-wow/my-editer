#lang racket

;;; layer  : model
;;; effect : 无（纯数据 + 纯栈操作）
;;;
;;; model/interaction.rkt —— 进行中的交互栈（LIFO）
;;;
;;; 一个 interaction = id + kind + data：
;;;   id   : symbol        稳定标识（'placement / 'confirm / 'input / tag）
;;;   kind : symbol        类别（'placement / 'confirm / 'input …）
;;;   data : any/c         该交互自己的参数
;;;
;;; 取消函数不在栈里，而在 environment.interactions：kind -> (ctx data -> transition)。
;;; 这样 State 里的 interaction 只是纯数据，不夹带闭包。
;;;
;;; 栈只记录“当前有哪些交互、取消时先找谁”；真正的状态仍然在原来的地方：
;;;   input      -> State.input.session-info
;;;   placement  -> workspace.placement
;;;   confirm    -> state.confirm
;;;   completion -> 插件 store + input.modes
;;;
;;; 约定：
;;;   · 新交互 push 到栈顶；
;;;   · 完成 / 取消时按 id 或 kind 移除（通常移除栈顶那一条）；
;;;   · cancel-current 先看 input 是否占用，再看栈顶，最后回退到 placement。
;;;
;;; 这样不把 pending / placement / confirm 的状态搬家，只把“取消顺序”收成数据。

(provide (struct-out interaction)
         make-interaction
         interaction-empty
         interaction-top
         interaction-push
         interaction-pop
         interaction-pop-id
         interaction-pop-kind
         interaction-find)

(struct interaction (id kind data) #:transparent)

(define (interaction-empty) '())

(define (make-interaction id kind data)
  (unless (symbol? id)
    (error 'make-interaction "id 要是 symbol：~a" id))
  (unless (symbol? kind)
    (error 'make-interaction "kind 要是 symbol：~a" kind))
  (interaction id kind data))

(define (interaction-top stack)
  (and (pair? stack) (car stack)))

(define (interaction-push stack i)
  (cons i stack))

(define (interaction-pop stack)
  (if (pair? stack) (cdr stack) '()))

;; 移除第一个匹配 id 的条目（LIFO：通常就是栈顶）。
(define (interaction-pop-id stack id)
  (cond
    [(null? stack) '()]
    [(eq? (interaction-id (car stack)) id) (cdr stack)]
    [else (cons (car stack) (interaction-pop-id (cdr stack) id))]))

;; 移除第一个匹配 kind 的条目。
(define (interaction-pop-kind stack kind)
  (cond
    [(null? stack) '()]
    [(eq? (interaction-kind (car stack)) kind) (cdr stack)]
    [else (cons (car stack) (interaction-pop-kind (cdr stack) kind))]))

(define (interaction-find stack id)
  (for/first ([i (in-list stack)] #:when (eq? (interaction-id i) id)) i))
