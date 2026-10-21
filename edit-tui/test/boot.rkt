#lang racket

;;; boot 最小骨架：host / plugin 列表 / install / sync / teardown。
(require rackunit
         "../main.rkt")

(define engine (make-engine))
(define order (box '()))
(define allocated (box #f))

(define p1
  (make-plugin
   #:id 'one
   #:install
   (λ (host state)
     (set-box! allocated (host-alloc-view-id! host))
     (set-box! order (cons 'one (unbox order)))
     (struct-copy app-state state
                  [store (hash-set (app-state-store state) 'one #t)]))
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

;; teardown 逆序
(define s2 (host-teardown host s1 engine))
(check-equal? (unbox order) '(teardown-one two one))
(check-equal? s2 s1)

;;; resource-open 的 doc-id 可以由宿主显式指定；create-buffer 后
;;; resource 版本必须按 resource-id 对齐，而不是拿 doc-id 当 resource-id。
(define engine2 (make-engine))
(define-values (store2 actions2)
  (resource-open resource-store-empty
                 #:name "doc-id-test"
                 #:text "hello"
                 #:doc-id 77
                 #:key-table (keys ['a 'a])))
(define state-doc (run-actions (make-app-state #:resources store2) engine2 actions2))
(define r-doc (car (resource-list (app-state-resources state-doc))))
(check-equal? (resource-id r-doc) 1)
(check-equal? (resource-doc-id r-doc) 77)
(check-false (resource-dirty? (app-state-resources state-doc) (resource-id r-doc)))

;;; close-resource：删 engine 句柄，但把 view 从 layout 摘掉、panel 保留。
(define vid (car (resource-view-ids (app-state-resources state-doc) (resource-id r-doc))))
(define p (make-panel 'editor 'editor #:views (list vid) #:active vid))
(define l (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor p)
                        #:focus 'editor))
(define state-layout
  (struct-copy app-state state-doc [layout l]))
(define-values (store-close close-actions)
  (resource-request-close (app-state-resources state-layout) (resource-id r-doc)))
(define state-close
  (run-actions (struct-copy app-state state-layout [resources store-close])
               engine2 close-actions))
(check-equal? (panel-views (layout-panel (app-state-layout state-close) 'editor)) '())
(check-false (panel-active (layout-panel (app-state-layout state-close) 'editor)))
(check-false (app-state-focus-resource state-close))

(displayln "edit-tui-rebuild/test/boot.rkt: ok")
