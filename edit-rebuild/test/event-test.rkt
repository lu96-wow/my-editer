#lang racket

;;; edit-rebuild/test/event-test.rkt —— 命令 execute + 生命周期事件 emit
;;;
;;; 旧树里，命令 handler 是一条 opaque 的 handler 链、生命周期 hook 是另一套 opaque 闭包，
;;; 而且 after-render 顺序一度依赖注册顺序（脆弱）。这里两者都是「trigger → action」的
;;; 路由，顺序由 priority 显式决定。

(require rackunit
         "harness.rkt")

(define host (mk-host))

;; execute 返回 (values st handled?)；测试只取 st。
(define (exec rss st cmd)
  (call-with-values (lambda () (execute host rss st 'focus cmd)) (lambda (st* _h) st*)))

;;; ---------- execute：命令命中 command 路由 ----------

(let* ([rss (list (route* (cmd-save) (addressed 'editor '(prim-save))))]
       [st (exec rss (state-new) (cmd-save))])
  (check-equal? (log-of st) '((editor (prim-save)))))

;;; ---------- execute：无命令路由 → 落宿主原语 ----------

(let* ([rss (list (route* (cmd-save) '(x)))]
       [st (exec rss (state-new) (cmd-noop))])
  (check-equal? (log-of st) (list (list 'focus (cmd-noop)))))

;;; ---------- execute：路由动作是 forward 命令 ----------

(let* ([rss (list (route* (cmd-save) (forward (cmd-other)))
                  (route* (cmd-other) '(other-ran)))]
       [st (exec rss (state-new) (cmd-save))])
  (check-equal? (log-of st) '((focus (other-ran)))))

;;; ---------- emit：所有命中的 reaction 都跑，按 priority ----------

(define erss
  (list (route* 'focus-changed (addressed 'editor '(focus-r)) #:priority 10)
        (route* 'focus-changed (addressed 'docs   '(focus-r)) #:priority 5)))

(let* ([st (emit host erss (state-new) (event 'focus-changed #f))])
  (check-equal? (log-of st) '((editor (focus-r)) (docs (focus-r)))))

;;; ---------- emit：作用域过滤（只在文档可见时关文档） ----------

(define nav-rss
  (list (route* 'after-nav (addressed 'docs '(close))
                #:when (scope-visible 'docs))))

(let* ([st (emit host nav-rss (state-new 'editor 'editor (hash 'docs #f)) (event 'after-nav 'v))])
  (check-equal? (log-of st) '()))

(let* ([st (emit host nav-rss (state-new 'editor 'editor (hash 'docs #t)) (event 'after-nav 'v))])
  (check-equal? (log-of st) '((docs (close)))))

;;; ---------- emit：未命中 → 原状态 ----------

(let* ([st (emit host erss (state-new) (event 'unknown #f))])
  (check-equal? (log-of st) '()))

;;; ---------- forward 事件 ----------

(define frss
  (list (route* 'a (forward (event 'b #f)))
        (route* 'b (addressed 'x '(from-b)))))
(let* ([st (emit host frss (state-new) (event 'a #f))])
  (check-equal? (log-of st) '((x (from-b)))))
