#lang racket

;;; edit-tui-rebuild/editor/contributions.rkt —— 非 hook 扩展点的统一注册表
;;;
;;; hook 有 typed context / phase；这里统一管理：
;;;   frame/sync       (ed state -> state')
;;;   frame/overlay    (ed state -> (listof editor-overlay))
;;;   timer            (ed state ps timer-event -> state' ps' actions)
;;;   job-service      kind -> handler payload -> result
;;;   job-result       kind -> (ed state ps job-result-event -> state' ps' actions)
;;;   command          scope -> command-binding（host 建 key -> ordered command 表）
;;;   key-owner        (ed state ps) -> scope | #f（completion 等 overlay 键盘层）
;;;
;;; 每条 contribution 都带 owner；job-service 同名冲突直接报错。

(require racket/list
         "../core/job/api.rkt"
         "points.rkt")

(provide (struct-out contribution)
         (struct-out contribution-registry)
         empty-contribution-registry
         add-contribution
         make-contribution-registry
         registry-contributions
         registry-services
         point/frame-sync
         point/frame-overlay
         point/timer
         point/job-service
         point/job-result
         point/command
         point/key-owner)

(define point/frame-sync 'frame/sync)
(define point/frame-overlay 'frame/overlay)
(define point/timer 'timer)
(define point/job-service 'job-service)
(define point/job-result 'job-result)
(define point/command 'command)
(define point/key-owner 'key-owner)

(struct contribution
  (point
   key            ; job kind / command scope / #f
   owner
   priority
   order
   fn)
  #:transparent)

;; table : hash (list point key) -> (listof contribution)
(struct contribution-registry
  (table next-order)
  #:transparent)

(define empty-contribution-registry (contribution-registry (hash) 0))

(define (check-contribution-point who point)
  (define spec (point-spec-of point))
  (unless spec
    (error who "未知 contribution point：~a" point))
  (unless (eq? (point-spec-kind spec) 'contribution)
    (error who "point ~a 不是 contribution point" point)))

(define (add-contribution registry point key owner
                          #:priority [priority 0]
                          #:fn fn)
  (check-contribution-point 'add-contribution point)
  (unless (symbol? owner)
    (raise-argument-error 'add-contribution "symbol?" owner))
  (define k (list point key))
  (define order (contribution-registry-next-order registry))
  (define c (contribution point key owner priority order fn))
  (contribution-registry
   (hash-update (contribution-registry-table registry) k
                (λ (old) (append old (list c)))
                '())
   (add1 order)))

(define (make-contribution-registry contributions)
  (define r
    (for/fold ([r empty-contribution-registry]) ([c (in-list contributions)])
      (add-contribution r (contribution-point c) (contribution-key c)
                        (contribution-owner c)
                        #:priority (contribution-priority c)
                        #:fn (contribution-fn c))))
  ;; 同名 job-service 在构建 registry 时直接报错。
  (for ([(k cs) (in-hash (contribution-registry-table r))]
        #:when (eq? (car k) point/job-service))
    (when (> (length cs) 1)
      (error 'make-contribution-registry "job service 冲突：~a（owners: ~a）"
             (cadr k) (map contribution-owner cs))))
  r)

(define (registry-contributions registry point [key #f])
  (map (λ (c) c)
       (sort (hash-ref (contribution-registry-table registry) (list point key) '())
             (λ (a b)
               (cond [(< (contribution-priority a) (contribution-priority b)) #t]
                     [(> (contribution-priority a) (contribution-priority b)) #f]
                     [else (< (contribution-order a) (contribution-order b))])))))

;; job-service kind 必须唯一；冲突报错。
(define (registry-services registry)
  (define rows
    (for/list ([(k cs) (in-hash (contribution-registry-table registry))]
               #:when (eq? (car k) point/job-service))
      (list (cadr k) cs)))
  (for/list ([row (in-list rows)])
    (define kind (car row))
    (define cs (cadr row))
    (when (> (length cs) 1)
      (error 'registry-services "job service 冲突：~a（owners: ~a）"
             kind (map contribution-owner cs)))
    (define c (car cs))
    (service kind (contribution-fn c))))
