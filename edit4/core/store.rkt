#lang racket

;;; edit4/core/store.rkt —— 插件局部状态：带类型的命名空间存储
;;;
;;; 插件需要私有状态（计数、缓存、在途标记…），但不该往 World 加散装 hash 字段，
;;; 也不该让 core 认识具体插件。于是给一个**类型化**的 store：
;;;   store : key -> value
;;; 约定 key 用 `(plugin-name . key)` 或插件自己的 symbol 命名空间，避免撞名。
;;; （edit3 的 feature-ref/feature-set 就是 State.views 上的这个 store。）

(provide (struct-out store) make-store store-ref store-set store-remove)

(struct store (table) #:transparent)          ; table : hash key -> value

(define (make-store) (store (hash)))
(define (store-ref s k [default #f]) (hash-ref (store-table s) k default))
(define (store-set s k v) (store (hash-set (store-table s) k v)))
(define (store-remove s k) (store (hash-remove (store-table s) k)))
