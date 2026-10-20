#lang racket

;;; edit-tui-rebuild/app/placement.rkt —— 把 view 放进目标 panel
;;;
;;; 流程：
;;;   filetree Enter on file
;;;     -> start-placement view-id
;;;        + 焦点不在 editor 时自动落到第一个 editor
;;;        + push placement-table（临时表，完毕 pop/remove）
;;;   placement-table:
;;;     ↑←→↓  在 editor 之间改焦点（跳过 filetree / status）
;;;     Enter 放入当前焦点 editor
;;;     Esc   取消
;;;   之后 clear-placement 把临时表从 overlays 里摘掉，普通键位恢复。

(require "../command/api.rkt"
         "../config/api.rkt"
         "../focus/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../resource/api.rkt"
         "state.rkt")

(provide placement-table
         start-placement
         clear-placement
         place-into-panel
         placement-commit
         placement-cancel
         placement-active?)

(define (notice state text)
  (struct-copy app-state state [message text]))

(define (focus-resource-of state id)
  (define p (layout-panel (app-state-layout state) id))
  (define vid (and p (panel-view p)))
  (and vid (resource-of-view (app-state-resources state) vid)))

(define (set-focus-panel state id)
  (define layout* (layout-set-focus (app-state-layout state) id))
  (define s1 (struct-copy app-state state [layout layout*]))
  (struct-copy app-state s1 [focus-resource (focus-resource-of s1 id)]))

(define (remove-placement-table overlays)
  (for/list ([t (in-list overlays)] #:unless (eq? t placement-table)) t))

(define (clear-placement state)
  (struct-copy app-state state
               [placement #f]
               [overlays (remove-placement-table (app-state-overlays state))]))

(define (panel-at state id)
  (and id (layout-panel (app-state-layout state) id)))

(define (editor-panel? state id)
  (define p (panel-at state id))
  (and p (eq? (panel-kind p) 'editor)))

(define (first-editor-panel state)
  (define layout (app-state-layout state))
  (and layout
       (for/first ([id (in-list (layout-visible-panel-ids layout))]
                   #:when (editor-panel? state id))
         id)))

;; placement 期间方向键只跳到 editor：filetree / status 不是合法目标。
(define (next-editor-in-direction state from dir)
  (let loop ([at from] [seen '()])
    (define next
      (layout-focus-neighbor (app-state-layout state) (app-state-area state)
                             default-config at dir))
    (cond
      [(not next) #f]
      [(memq next seen) #f]
      [(editor-panel? state next) next]
      [else (loop next (cons next seen))])))

(define (placement-focus-command dir)
  (λ (state)
    (define from (layout-focus (app-state-layout state)))
    (define to (next-editor-in-direction state from dir))
    (cond
      [to (values (set-focus-panel state to) '())]
      [else (values (struct-copy app-state state
                                 [message (format "place: no editor to the ~a" dir)])
                    '())])))

(define (start-placement state vid)
  (unless vid (error 'start-placement "view-id 不能是 #f"))
  (define s1
    (struct-copy app-state state
                 [placement vid]
                 [overlays (cons placement-table (app-state-overlays state))]))
  ;; 焦点不在 editor 上时先落一个：Enter 立刻可放入，方向键可换目标。
  ;; （headless 测试可能没有 layout，此时只装表。）
  (define layout (app-state-layout s1))
  (cond
    [(not layout) s1]
    [(editor-panel? s1 (layout-focus layout)) s1]
    [else
     (define target (first-editor-panel s1))
     (if target (set-focus-panel s1 target) s1)]))

(define (placement-active? state)
  (and (app-state-placement state) #t))

(define (place-into-panel state pid)
  (define vid (app-state-placement state))
  (define p (and pid (layout-panel (app-state-layout state) pid)))
  (cond
    [(not vid) (values state '())]
    [(not p) (values (notice state "place: no target panel") '())]
    [(not (eq? (panel-kind p) 'editor))
     (values (notice state "place: target is not an editor panel") '())]
    [else
     (define-values (layout* ok?)
       (layout-panel-add-view (app-state-layout state) pid vid))
     (if (not ok?)
         (values (notice state "place: target panel missing") '())
         (let* ([s1 (struct-copy app-state state [layout layout*])]
                [s2 (set-focus-panel s1 pid)]
                [s3 (clear-placement s2)])
           (values (struct-copy app-state s3 [message "view placed"]) '())))]))

(define (placement-commit state)
  (place-into-panel state (layout-focus (app-state-layout state))))

(define (placement-cancel state)
  (define s (clear-placement state))
  (values (struct-copy app-state s [message "placement cancelled"]) '()))

(define placement-table
  (keys
   [(key 'enter)  placement-commit]
   [(key 'escape) placement-cancel]
   [(key 'left)   (placement-focus-command 'left)]
   [(key 'right)  (placement-focus-command 'right)]
   [(key 'up)     (placement-focus-command 'up)]
   [(key 'down)   (placement-focus-command 'down)]))
