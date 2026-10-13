#lang racket

;;; edit4/plugins/sync/session.rkt —— 配对状态（存 World.store）
;;;
;;; session = 两篇文档的 did + 用哪条 mapping。did 稳定；vid 每次现取。
;;; 双向：哪边触发就以哪边为源、另一边为 peer。

(provide (struct-out session)
         sessions session-add session-remove-did session-for-did peer-did fresh-session-id)

(require racket/list
         "../../core/world.rkt" "../../core/store.rkt")

(struct session (id a b mapping-id) #:transparent)
;; a 对应 mapping 的 a-lang，b 对应 b-lang

(define key 'sync-sessions)

(define (sessions w) (store-ref (world-store w) key '()))
(define (set-sessions w ss) (world-set-store w (store-set (world-store w) key ss)))

(define (fresh-session-id w)
  (add1 (for/fold ([m -1]) ([s (in-list (sessions w))]) (max m (session-id s)))))

(define (session-add w s) (set-sessions w (cons s (sessions w))))

(define (session-remove-did w did)
  (set-sessions w
                (filter (lambda (s) (not (or (eqv? did (session-a s)) (eqv? did (session-b s)))))
                        (sessions w))))

(define (session-for-did w did)
  (for/first ([s (in-list (sessions w))]
              #:when (or (eqv? did (session-a s)) (eqv? did (session-b s))))
    s))

(define (peer-did s did)
  (if (eqv? did (session-a s)) (session-b s) (session-a s)))
