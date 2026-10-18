#lang racket

;;; base/id.rkt —— 稳定身份 + 单调分配器（纯）
;;; layer  : base
;;; effect : 无（纯值 + 纯分配器）

;;; State 只存 id，不存 core 的 buffer / view 句柄（见 DESIGN.md 方案 B）。
;;; id 是带 kind 的透明结构：doc / view / region / job。kind 让不同命名空间
;;; 不会撞值，也方便日志和断言。
;;;
;;; 分配器 id-counter 是 State 的字段：分配是纯的（返回新 counter），
;;; 因此同一串事件可以确定性地重放出同一批 id。

(provide (struct-out id)
         (struct-out id-counter)
         doc-id? view-id? region-id? job-id?
         id->string id=?
         make-id-counter id-counter-next
         doc-id view-id region-id job-id
         next-id)

;; kind : 'doc | 'view | 'region | 'job | …
;; n    : positive integer
;;
;; `#:prefab`：id 会作为 job payload 跨 place（后台 worker）传递，
;; 需要可序列化；prefab 仍然支持 equal? 比较与 struct-copy。
(struct id (kind n) #:prefab)

(define (doc-id? x)    (and (id? x) (eq? (id-kind x) 'doc)))
(define (view-id? x)   (and (id? x) (eq? (id-kind x) 'view)))
(define (region-id? x) (and (id? x) (eq? (id-kind x) 'region)))
(define (job-id? x)    (and (id? x) (eq? (id-kind x) 'job)))

(define (id->string x)
  (format "~a:~a" (id-kind x) (id-n x)))

;; id 用 equal? 比较即可（transparent struct）。
(define (id=? a b) (equal? a b))

;; 构造函数：只暴露按 kind 命名的入口，避免调用方记住整张 kind 表。
(define (doc-id n)    (id 'doc n))
(define (view-id n)   (id 'view n))
(define (region-id n) (id 'region n))
(define (job-id n)    (id 'job n))

;;; ---------- 分配器 ----------

(struct id-counter (doc view region job) #:transparent)
;; 各字段是「下一个可用编号」。

(define (make-id-counter [doc 1] [view 1] [region 1] [job 1])
  (id-counter doc view region job))

;; 取一个 id，并返回新 counter。未知 kind -> error（尽早暴露拼写错误）。
(define (id-counter-next c kind)
  (define (bump v) (values v (add1 v)))
  (case kind
    [(doc)    (define-values (n n*) (bump (id-counter-doc c)))
              (values (doc-id n)    (struct-copy id-counter c [doc n*]))]
    [(view)   (define-values (n n*) (bump (id-counter-view c)))
              (values (view-id n)   (struct-copy id-counter c [view n*]))]
    [(region) (define-values (n n*) (bump (id-counter-region c)))
              (values (region-id n) (struct-copy id-counter c [region n*]))]
    [(job)    (define-values (n n*) (bump (id-counter-job c)))
              (values (job-id n)    (struct-copy id-counter c [job n*]))]
    [else (error 'id-counter-next "未知 id kind：~a" kind)]))

;; 便捷：分配一个 id（不返回新 counter）。需要确定性时用 id-counter-next。
(define (next-id c kind)
  (call-with-values (λ () (id-counter-next c kind)) (λ (i _) i)))
