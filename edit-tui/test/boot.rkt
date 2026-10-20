#lang racket

;;; boot 最小骨架：host / plugin 列表 / install / sync / teardown。
(require rackunit
         "../main.rkt")

(define engine (make-engine))
(define order (box '()))
(define allocated (box #f))
(define synced (box 0))

(define p1
  (make-plugin
   #:id 'one
   #:install
   (λ (host state)
     (set-box! allocated (host-alloc-view-id! host))
     (set-box! order (cons 'one (unbox order)))
     (struct-copy app-state state
                  [store (hash-set (app-state-store state) 'one #t)]))
   #:sync (λ (state engine)
            (set-box! synced (add1 (unbox synced)))
            state)
   #:teardown (λ (state engine)
                (set-box! order (cons 'teardown-one (unbox order)))
                state)))

(define p2
  (make-plugin
   #:id 'two
   #:install
   (λ (host state)
     (set-box! order (cons 'two (unbox order)))
     (check-true (hash-ref (app-state-store state) 'one #f))
     state)))

(define host
  (make-host #:engine engine #:plugins (list p1 p2)))

(define s0 (make-app-state))
(define s1 (start-app host s0))

;; install 按列表顺序；p2 能看到 p1 写入 state 的数据
(check-equal? (unbox order) '(two one))
(check-true (hash-ref (app-state-store s1) 'one #f))
(check-equal? (unbox allocated) 10)
(check-equal? (host-alloc-view-id! host) 11)

;; sync hooks 按插件顺序收集
(define sync-hooks (host-sync-hooks host))
(check-equal? (length sync-hooks) 1)
(define s2 (sync-ui! s1 engine #:hooks sync-hooks))
(check-equal? (unbox synced) 1)
(check-equal? (app-state-store s2) (app-state-store s1))

;; teardown 逆序
(define s3 (host-teardown host s2 engine))
(check-equal? (unbox order) '(teardown-one two one))
(check-equal? s3 s2)

(displayln "edit-tui-rebuild/test/boot.rkt: ok")
