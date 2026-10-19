#lang racket

;;; edit-tui-rebuild/runtime/engine.rkt —— core buffer / view 的唯一拥有者
;;;
;;; 纯 State 只存 id；engine 存真正可变句柄。
;;; 命令 / step 不碰 engine，只产生 action；runtime 解释 action 时写 engine。

(require "../../core/editor.rkt"
         "../app/action.rkt")

(provide (struct-out engine)
         make-engine
         engine-doc-buffer engine-view-object
         engine-create-buffer! engine-create-view!
         engine-remove-view! engine-remove-doc!
         engine-view-text engine-doc-text engine-doc-version
         engine-apply-view-action!)

(struct engine (docs views) #:mutable)

(define (make-engine)
  (engine (hash) (hash)))

(define (engine-doc-buffer e did)
  (hash-ref (engine-docs e) did #f))

(define (engine-view-object e vid)
  (hash-ref (engine-views e) vid #f))

(define (engine-create-buffer! e did name text)
  (define b (make-buffer text name))
  (set-engine-docs! e (hash-set (engine-docs e) did b))
  b)

(define (engine-create-view! e vid did)
  (define b (engine-doc-buffer e did))
  (unless b (error 'engine-create-view! "doc 不存在：~a" did))
  (define v (buffer-add-view! b 1 1))
  (set-engine-views! e (hash-set (engine-views e) vid v))
  v)

(define (engine-remove-view! e vid)
  (define v (engine-view-object e vid))
  (when v
    (buffer-close-view! (view-buffer v) v)
    (set-engine-views! e (hash-remove (engine-views e) vid)))
  (void))

(define (engine-remove-doc! e did)
  (define b (engine-doc-buffer e did))
  (when b
    (define vids
      (for/list ([(vid v) (in-hash (engine-views e))]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (set-engine-docs! e (hash-remove (engine-docs e) did)))
  (void))

(define (engine-view-text e vid)
  (define v (engine-view-object e vid))
  (and v (view-string v)))

(define (engine-doc-text e did)
  (define b (engine-doc-buffer e did))
  (and b (buffer-string b)))

(define (engine-doc-version e did)
  (define b (engine-doc-buffer e did))
  (and b (buffer-version b)))

(define (apply-nav! v dir)
  (case dir
    [(left) (view-left! v)]
    [(right) (view-right! v)]
    [(up) (view-up! v)]
    [(down) (view-down! v)]
    [(home) (view-home! v)]
    [(end) (view-end! v)]
    [else (error 'engine-apply-view-action! "未知方向：~a" dir)]))

(define (engine-apply-view-action! e action)
  (define vid (view-action-view-id action))
  (define v (engine-view-object e vid))
  (unless v (error 'engine-apply-view-action! "view 不存在：~a" vid))
  (case (view-action-kind action)
    [(insert)
     (buffer-edit! (view-buffer v) v (op-type (view-action-data action)))]
    [(nav)
     (apply-nav! v (view-action-data action))]
    [(select)
     (view-set-selections! v (view-action-data action))]
    [(scroll)
     (view-scroll! v (view-action-data action))]
    [(ensure)
     (view-ensure! v)]
    [(undo) (buffer-undo! (view-buffer v))]
    [(redo) (buffer-redo! (view-buffer v))]
    [else (error 'engine-apply-view-action! "未知 view action：~a" action)])
  (void))
