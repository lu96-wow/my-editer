#lang racket

;;; edit-tui-rebuild/editor/hooks.rkt —— 显式扩展点 / 有序 pipeline
;;;
;;; 语义是“有序管道”，不是简单的 map：
;;;   hook : edit-context × plugin-state
;;;          -> (values edit-context' plugin-state' actions allow?)
;;;
;;; - allow? = #f 只会中止 before 阶段；after 阶段忽略 allow?。
;;; - 每个 hook 只拿到自己的 plugin-state；返回新值后由 runner 写回 State。
;;; - actions 按 hook 顺序追加，交给 host 在操作结束后执行。
;;; - 顺序：priority 小者先；同 priority 按注册顺序。
;;;
;;; 扩展点暂定：
;;;   operation 'insert  phase 'validate / 'transform / 'derive / 'observe
;;;   operation 'delete  phase 'validate / 'transform / 'derive / 'observe
;;;
;;; before 阶段按 validate -> transform 跑；after 阶段按 derive -> observe 跑。
;;; 以后加 replace / move / layout 时只加 operation 名字，不引入 registry / discovery。

(require "../core/api.rkt"
         "state.rkt")

(provide (struct-out edit-context)
         make-edit-context
         (struct-out change-context)
         make-change-context
         (struct-out hook)
         make-hook
         (struct-out hook-registry)
         empty-hook-registry
         add-hook
         make-hook-registry
         registry-hooks
         run-before-hooks
         run-after-hooks)

;;; ════════════════ 操作上下文 ════════════════

;; kind    : 'insert | 'backspace | 'delete | ...（操作种类；delete 的细分也放这里）
;; point   : 操作发生前的光标（core point）
;; text    : insert 要插入的文本；delete 为 #f
;; count   : delete 的次数（backspace/delete 默认 1；pair 插件可改成 2）
;; caret-delta : 提交后光标相对移动量（负 = 左移）
;; result  : after 阶段的 changes；before 为 #f
(struct edit-context
  (engine
   state
   view-id
   kind
   point
   text
   count
   caret-delta
   result
   delete-plan)   ; #f | (listof 'backspace|'delete)，before hook 可覆盖删除序列
  #:transparent)

(define (make-edit-context engine state view-id kind
                           #:point point
                           #:text [text #f]
                           #:count [count 1]
                           #:caret-delta [caret-delta 0]
                           #:result [result #f]
                           #:delete-plan [delete-plan #f])
  (edit-context engine state view-id kind point text count caret-delta result delete-plan))

;; 一次 surface 操作产生的 change 批次；用于着色 / workspace / completion 等派生。
;; operation 固定为 'changes。
(struct change-context
  (engine
   state
   doc-id
   base-version   ; 本次操作前的 document version
   version        ; 操作后的 document version
   changes)
  #:transparent)

(define (make-change-context engine state doc-id base-version version changes)
  (change-context engine state doc-id base-version version changes))

;;; ════════════════ hook 定义 ════════════════

(struct hook
  (owner          ; plugin-id
   id             ; 插件内唯一
   operation      ; symbol
   phase          ; 'validate | 'transform | 'derive | 'observe
   priority       ; integer，小者先
   fn)            ; edit-context plugin-state -> (values ctx' ps' actions allow?)
  #:transparent)

(define (make-hook #:owner owner
                   #:id id
                   #:operation operation
                   #:phase phase
                   #:priority [priority 0]
                   #:fn fn)
  (unless (symbol? owner)
    (raise-argument-error 'make-hook "symbol?" owner))
  (unless (memq phase '(validate transform derive observe))
    (raise-argument-error 'make-hook
                          "(or/c 'validate 'transform 'derive 'observe)"
                          phase))
  (hook owner id operation phase priority fn))

;;; ════════════════ registry ════════════════

;; table : hash (cons operation phase) -> (listof (cons order hook))
(struct hook-registry (table next-order) #:transparent)

(define empty-hook-registry (hook-registry (hash) 0))

(define (add-hook registry h)
  (define key (cons (hook-operation h) (hook-phase h)))
  (define order (hook-registry-next-order registry))
  (define old (hash-ref (hook-registry-table registry) key '()))
  (hook-registry (hash-set (hook-registry-table registry) key
                           (append old (list (cons order h))))
                 (add1 order)))

(define (make-hook-registry hooks)
  (for/fold ([r empty-hook-registry]) ([h (in-list hooks)])
    (add-hook r h)))

;; 按 priority、再按注册顺序。
(define (registry-hooks registry operation phase)
  (define entries
    (hash-ref (hook-registry-table registry) (cons operation phase) '()))
  (map cdr
       (sort entries
             (λ (a b)
               (define ha (cdr a))
               (define hb (cdr b))
               (cond
                 [(< (hook-priority ha) (hook-priority hb)) #t]
                 [(> (hook-priority ha) (hook-priority hb)) #f]
                 [else (< (car a) (car b))])))))

;;; ════════════════ 执行 ════════════════

;; → (values ctx' state' actions allow?)
(define (run-phase registry operation phase ctx state
                   #:stop-on-false? [stop-on-false? #t])
  (let loop ([hs (registry-hooks registry operation phase)]
             [ctx ctx]
             [st state]
             [actions '()]
             [allow? #t])
    (cond
      [(or (null? hs) (not allow?))
       (values ctx st actions allow?)]
      [else
       (define h (car hs))
       (define owner (hook-owner h))
       (define ps (editor-state-plugin-state st owner))
       (define-values (ctx* ps* acts* ok?*)
         ((hook-fn h) ctx ps))
       (define st* (editor-state-set-plugin-state st owner ps*))
       ;; ctx 可以是 edit-context 或 layout-context；runner 不假设具体类型。
       ;; 插件状态以 ps* 为准，ctx.state 只保留操作开始时的快照。
       (loop (cdr hs) ctx* st*
             (append actions acts*)
             (if stop-on-false? ok?* #t))])))

;; before = validate -> transform；任一阶段 veto 就停止。
(define (run-before-hooks registry operation ctx state)
  (define-values (ctx1 st1 actions1 ok1?)
    (run-phase registry operation 'validate ctx state))
  (cond
    [(not ok1?) (values ctx1 st1 actions1 #f)]
    [else
     (define-values (ctx2 st2 actions2 ok2?)
       (run-phase registry operation 'transform ctx1 st1))
     (values ctx2 st2 (append actions1 actions2) ok2?)]))

;; after = derive -> observe；after 阶段不因为某个 hook 返回 #f 而中断。
(define (run-after-hooks registry operation ctx state)
  (define-values (ctx1 st1 actions1 _ok1?)
    (run-phase registry operation 'derive ctx state #:stop-on-false? #f))
  (define-values (ctx2 st2 actions2 _ok2?)
    (run-phase registry operation 'observe ctx1 st1 #:stop-on-false? #f))
  (values ctx2 st2 (append actions1 actions2)))
