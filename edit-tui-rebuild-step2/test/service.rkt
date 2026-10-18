#lang racket

;;; edit-tui/test/service.rkt —— 通用 service 状态（cache / pending / jobs）
;;;
;;; completion / docs 共用这套纯结构；这里只测纯函数，不碰 worker。
;;;
;;; 覆盖：
;;;   1. cache：set / ref / has / remove；结果可以是 #f；
;;;   2. pending：add / del / 同一 key 只标记；
;;;   3. jobs：job-id -> tag，take 后删除，未知 id -> #f；
;;;   4. 所有操作返回新值，旧 service 不变。

(require rackunit
         "../base/id.rkt"
         "../base/effect.rkt"
         "../model/state.rkt"
         "../model/service.rkt")

(define s0 (service-empty))

;;; ════════════════ cache ════════════════

(check-false (service-cache-has? s0 'a))
(check-eq? (service-cache-ref s0 'a 'missing) 'missing)

(define s1 (service-cache-set s0 'a '(1 2 3)))
(check-true (service-cache-has? s1 'a))
(check-equal? (service-cache-ref s1 'a) '(1 2 3))
;; 旧值不变（纯）
(check-false (service-cache-has? s0 'a))

;; 结果可以是 #f：has? 才是“有没有”
(define s2 (service-cache-set s1 'b #f))
(check-true (service-cache-has? s2 'b))
(check-false (service-cache-ref s2 'b #t))
(check-false (service-cache-ref s2 'b 'missing))
(check-eq? (service-cache-ref s2 'b 'missing) #f)

(define s3 (service-cache-remove s2 'a))
(check-false (service-cache-has? s3 'a))
(check-true (service-cache-has? s3 'b))

;;; ════════════════ pending ════════════════

(check-false (service-pending? s0 'k))
(define p1 (service-pending-add s0 'k))
(check-true (service-pending? p1 'k))
(check-false (service-pending? s0 'k))
(define p2 (service-pending-del p1 'k))
(check-false (service-pending? p2 'k))
;; 重复 add 幂等（值都是 #t）
(check-true (service-pending? (service-pending-add p1 'k) 'k))

;;; ════════════════ jobs ════════════════

(check-false (service-job-tag s0 'j1))
(define j1 (service-job-add s0 'j1 'tag-1))
(check-eq? (service-job-tag j1 'j1) 'tag-1)
(check-false (service-job-tag s0 'j1))

(define j2 (service-job-add j1 'j2 (cons 'doc 'k2)))
(check-equal? (service-job-tag j2 'j2) (cons 'doc 'k2))

(define-values (tag j3) (service-job-take j2 'j1))
(check-eq? tag 'tag-1)
(check-false (service-job-tag j3 'j1))
(check-equal? (service-job-tag j3 'j2) (cons 'doc 'k2))
;; 未知 job -> #f，service 不变
(define-values (none j4) (service-job-take j3 'nope))
(check-false none)
(check-equal? j4 j3)

;;; ════════════════ 一次 request ════════════════

(define st0 (make-state #:ids (make-id-counter 1 1 1 1)))
(define sv (service-empty))
(define-values (st1 sv* eff)
  (service-request st0 sv 'demo 'payload 'tag))
(check-true (query-effect? eff))
(check-eq? (query-effect-kind eff) 'demo)
(check-equal? (query-effect-payload eff) 'payload)
(check-true (service-pending? sv* 'tag))
(check-eq? (service-job-tag sv* (query-effect-job eff)) 'tag)
(check-eq? (id-counter-job (state-ids st1)) 2)
;; 旧 state / service 不变
(check-eq? (id-counter-job (state-ids st0)) 1)
(check-false (service-pending? sv 'tag))

(displayln "edit-tui service: ok")
