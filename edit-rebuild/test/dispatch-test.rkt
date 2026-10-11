#lang racket

;;; edit-rebuild/test/dispatch-test.rkt —— 派发：策略 / 寻址 / 模式 / 前缀 / 替换 / 广播

(require rackunit
         "harness.rkt")

(define host (mk-host))

;;; ---------- 文本通道：载荷型 spec → 命令 ----------

(let* ([rss (list (route* (text-binding) text-spec))]
       [st (dispatch host rss (state-new) (input (text-binding) "hi" #f #f #f #f))])
  (check-equal? (log-of st) '((focus (ins "hi")))))

;;; ---------- policy：stop（高优先接了就停） ----------

(let* ([rss (list (route* (key 'x) '(high) #:priority 10 #:policy 'stop)
                  (route* (key 'x) '(low)  #:priority 0))]
       [st (dispatch host rss (state-new) (input (key 'x) #f #f #f #f #f))])
  (check-equal? (log-of st) '((focus (high)))))

;;; ---------- policy：continue（高优先继续，低优先也跑） ----------

(let* ([rss (list (route* (key 'x) '(high) #:priority 10 #:policy 'continue)
                  (route* (key 'x) '(low)  #:priority 0))]
       [st (dispatch host rss (state-new) (input (key 'x) #f #f #f #f #f))])
  (check-equal? (log-of st) '((focus (high)) (focus (low)))))

;;; ---------- pass：高优先没接住 → 落到低优先 ----------

(let* ([host2 (mk-host (lambda (cmd) (equal? cmd '(skip))))]
       [rss (list (route* (key 'x) '(skip) #:priority 10)
                  (route* (key 'x) '(real) #:priority 0))]
       [st (dispatch host2 rss (state-new) (input (key 'x) #f #f #f #f #f))])
  (check-equal? (log-of st) '((focus (real)))))

;;; ---------- 寻址：命令发给指定目标，而不是焦点 ----------

(let* ([rss (list (route* (key 'j) (addressed 'docs '(scroll 1))))]
       [st (dispatch host rss (state-new) (input (key 'j) #f #f #f #f #f))])
  (check-equal? (log-of st) '((docs (scroll 1)))))

;;; ---------- 一键管两窗：两条 scope 都命中的 route ----------

(let* ([rss (list (route* (key 'l) (addressed 'docs (list 'scroll -1))
                          #:when (scope-visible 'docs) #:priority 10)
                  (route* (key 'l) (addressed 'editor (list 'move 'right)) #:priority 0))]
       [st (dispatch host rss (state-new) (input (key 'l) #f #f #f #f #f))])
  ;; 高优先接了就停 → 只滚文档
  (check-equal? (log-of st) '((docs (scroll -1)))))

(let* ([rss (list (route* (key 'l) (addressed 'docs (list 'scroll -1))
                          #:when (scope-visible 'docs) #:priority 10 #:policy 'continue)
                  (route* (key 'l) (addressed 'editor (list 'move 'right)) #:priority 0))]
       [st (dispatch host rss (state-new) (input (key 'l) #f #f #f #f #f))])
  ;; policy='continue → 两个窗口都收到
  (check-equal? (log-of st) '((docs (scroll -1)) (editor (move right)))))

;;; ---------- 模式：set-mode 后 scope 才生效 ----------

(let* ([rss (list (route* (key 'm) (set-mode 'interaction 'docs))
                  (route* (key 'y) '(docs-only)
                          #:when (scope-mode= 'interaction 'docs)))]
       [s0 (dispatch host rss (state-new) (input (key 'y) #f #f #f #f #f))]   ; 模式未设 → 无命中
       [s1 (dispatch host rss s0 (input (key 'm) #f #f #f #f #f))]
       [s2 (dispatch host rss s1 (input (key 'y) #f #f #f #f #f))])
  (check-equal? (log-of s0) '())
  (check-equal? (state-modes s1) (hash 'interaction 'docs))
  (check-equal? (log-of s2) '((focus (docs-only)))))

;;; ---------- 焦点：focus-to ----------

(let* ([rss (list (route* (key 'tab) (focus-to 'docs)))]
       [st (dispatch host rss (state-new) (input (key 'tab) #f #f #f #f #f))])
  (check-equal? (state-focus st) 'docs))

;;; ---------- 前缀：begin-prefix / 命中后清除 / 未命中取消 ----------

(define prss
  (list (route* (key 'p 'ctrl) (begin-prefix 'C-p))
        (route* (key 'd) '(pfx-d) #:prefix 'C-p)))

(let* ([s1 (dispatch host prss (state-new) (input (key 'p 'ctrl) #f #f #f #f #f))]
       [s2 (dispatch host prss s1 (input (key 'd) #f #f #f #f #f))])
  (check-equal? (state-prefix s1) 'C-p)
  (check-equal? (log-of s2) '((focus (pfx-d))))
  (check-false (state-prefix s2)))                      ; 命中后清除

(let* ([s1 (dispatch host prss (state-new) (input (key 'p 'ctrl) #f #f #f #f #f))]
       [s2 (dispatch host prss s1 (input (key 'z) #f #f #f #f #f))])
  (check-false (state-prefix s2))                       ; 未命中 → 取消
  (check-equal? (log-of s2) '()))

;; 嵌套前缀：动作里再 begin-prefix
(define nrss
  (list (route* (key 'a 'ctrl) (begin-prefix 'A))
        (route* (key 'b) (begin-prefix 'B) #:prefix 'A)
        (route* (key 'c) '(abc) #:prefix 'B)))
(let* ([s1 (dispatch host nrss (state-new) (input (key 'a 'ctrl) #f #f #f #f #f))]
       [s2 (dispatch host nrss s1 (input (key 'b) #f #f #f #f #f))]
       [s3 (dispatch host nrss s2 (input (key 'c) #f #f #f #f #f))])
  (check-equal? (state-prefix s2) 'B)
  (check-equal? (log-of s3) '((focus (abc)))))

;;; ---------- 事件替换：forward ----------

(define frss
  (list (route* (key 'a) (forward (input (key 'b) #f #f #f #f #f)))
        (route* (key 'b) '(from-b))))
(let* ([st (dispatch host frss (state-new) (input (key 'a) #f #f #f #f #f))])
  (check-equal? (log-of st) '((focus (from-b)))))

;;; ---------- 广播：同一命令发往多个目标 ----------

(define brss (list (route* (key 'esc) (broadcast '(complete docs) '(close)))))
(let* ([st (dispatch host brss (state-new) (input (key 'esc) #f #f #f #f #f))])
  (check-equal? (log-of st) '((complete (close)) (docs (close)))))

;;; ---------- seq：顺序效果 ----------

(define srss
  (list (route* (key 's)
                (seq-effect (list (addressed 'editor '(save))
                                  (set-mode 'saved #t)
                                  (addressed 'docs '(close)))))))
(let* ([st (dispatch host srss (state-new) (input (key 's) #f #f #f #f #f))])
  (check-equal? (log-of st) '((editor (save)) (docs (close))))
  (check-equal? (hash-ref (state-modes st) 'saved #f) #t))
