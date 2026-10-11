#lang racket

;;; edit-rebuild/test/scenario-test.rkt —— 用骨架表达真实场景：Tab 进文档 + 两窗同键
;;;
;;; 这正是旧模型（焦点 + 单命中键表 + hook 转发）写不出来的：
;;;   · 文档窗显示时，Tab 在“补全接键 / 文档接键”间循环（modes + scope）；
;;;   · 上下随模式路由到两个不同窗口；
;;;   · 左右无视焦点、只要文档可见就滚文档（两窗“同时生效”）；
;;;   · Esc 广播关闭两个窗口。

(require rackunit
         "harness.rkt")

;; 初始：焦点在编辑器；补全菜单开着、文档窗可见、当前接键的是补全。
(define (initial)
  (state-new 'editor 'editor
             (hash 'docs #t)
             (hash 'interaction 'complete 'menu 'open)))

(define rss
  (list
   ;; Tab：文档可见时在“补全 / 文档”两种接键态间循环
   (route* (key 'tab) (set-mode 'interaction 'docs)
           #:when (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'complete))
           #:priority 20)
   (route* (key 'tab) (set-mode 'interaction 'complete)
           #:when (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'docs))
           #:priority 20)
   ;; 上下：按 interaction 路由到对应窗口
   (route* (key 'up) (addressed 'docs (list 'scroll -1))
           #:when (scope-mode= 'interaction 'docs) #:priority 30)
   (route* (key 'down) (addressed 'docs (list 'scroll 1))
           #:when (scope-mode= 'interaction 'docs) #:priority 30)
   (route* (key 'up) (addressed 'complete (list 'move -1))
           #:when (scope-mode= 'interaction 'complete) #:priority 30)
   (route* (key 'down) (addressed 'complete (list 'move 1))
           #:when (scope-mode= 'interaction 'complete) #:priority 30)
   ;; 左右：文档可见就生效（与焦点 / 模式无关）—— “两窗同时生效”
   (route* (key 'left) (addressed 'docs (list 'scroll -1))
           #:when (scope-visible 'docs) #:priority 10)
   (route* (key 'right) (addressed 'docs (list 'scroll 1))
           #:when (scope-visible 'docs) #:priority 10)
   ;; Esc：广播关闭两个窗口
   (route* (key 'escape) (broadcast '(complete docs) (list 'close)) #:priority 5)))

(define host (mk-host))
(define (press st k) (dispatch host rss st (input (key k) #f #f #f #f #f)))

(define s0 (initial))

(define s1 (press s0 'tab))                 ; 进文档
(check-equal? (hash-ref (state-modes s1) 'interaction) 'docs)

(define s2 (press s1 'up))                  ; 滚文档
(check-equal? (last (log-of s2)) '(docs (scroll -1)))

(define s3 (press s2 'tab))                 ; 回补全
(check-equal? (hash-ref (state-modes s3) 'interaction) 'complete)

(define s4 (press s3 'up))                  ; 移候选
(check-equal? (last (log-of s4)) '(complete (move -1)))

(define s5 (press s4 'left))                ; 左右无视模式，仍滚文档
(check-equal? (last (log-of s5)) '(docs (scroll -1)))

(define s6 (press s5 'escape))              ; 广播关两窗
(check-equal? (take-right (log-of s6) 2) '((complete (close)) (docs (close))))

;; 文档不可见时 Tab / 左右都不命中（scope 生效）
(define hidden (state-new 'editor 'editor (hash 'docs #f) (hash 'interaction 'complete)))
(define h1 (press hidden 'tab))
(define h2 (press h1 'left))
(check-equal? (log-of h2) '())
(check-equal? (hash-ref (state-modes h2) 'interaction) 'complete)
