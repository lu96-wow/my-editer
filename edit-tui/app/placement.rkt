#lang racket

;;; edit-tui-rebuild/app/placement.rkt —— “把 view 放进目标 editor” 的交互
;;;
;;; 流程：
;;;   文件树 Enter on file
;;;     -> start-placement view-id
;;;        + 焦点若不在 editor，自动落到第一个 editor
;;;        + 压入 placement-table（临时 keymap，结束时摘掉）
;;;   placement-table:
;;;     ↑←→↓  在 editor 之间改焦点（跳过 sidebar / status）
;;;     Enter 放入当前焦点 editor
;;;     Esc   取消
;;;   之后 clear-placement 把临时表从 overlays 里移除，普通键位恢复。

(require "../skeleton.rkt"
         "state.rkt")

(provide placement-table
         start-placement
         place-into-panel
         placement-commit
         placement-cancel
         placement-active?)

;;; ════════════════ 临时 keymap ════════════════

(define (remove-placement-table overlays)
  (for/list ([t (in-list overlays)] #:unless (eq? t placement-table)) t))

(define (clear-placement state)
  (struct-copy app-state state
               [placement #f]
               [overlays (remove-placement-table (app-state-overlays state))]))

(define (placement-active? state)
  (and (app-state-placement state) #t))

;;; ════════════════ 目标选择 ════════════════

(define (editor-panel-id? state pid)
  (define p (app-state-panel state pid))
  (and p (eq? (panel-kind p) 'editor)))

(define (first-editor-panel-id state)
  (define layout (app-state-layout state))
  (and layout
       (for/first ([id (in-list (layout-visible-panel-ids layout))]
                   #:when (editor-panel-id? state id))
         id)))

;; placement 期间方向键只跳到 editor：filetree / status 不是合法目标。
(define (next-editor-in-direction state from dir)
  (define layout (app-state-layout state))
  (let loop ([at from] [seen '()])
    (define next (layout-focus-neighbor layout (app-state-area state)
                                        default-config at dir))
    (cond
      [(not next) #f]
      [(memq next seen) #f]
      [(editor-panel-id? state next) next]
      [else (loop next (cons next seen))])))

(define (placement-focus-command dir)
  (λ (state)
    (define from (app-state-focus-panel-id state))
    (define to (next-editor-in-direction state from dir))
    (cond
      [to (values (app-state-set-focus-panel state to) '())]
      [else (values (app-state-with-message
                     state
                     (format "place: no editor to the ~a" dir))
                    '())])))

;;; ════════════════ 开始 / 提交 / 取消 ════════════════

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
    [(editor-panel-id? s1 (app-state-focus-panel-id s1)) s1]
    [else
     (define target (first-editor-panel-id s1))
     (if target (app-state-set-focus-panel s1 target) s1)]))

(define (place-into-panel state pid)
  (define vid (app-state-placement state))
  (define p (app-state-panel state pid))
  (cond
    [(not vid) (values state '())]
    [(not p) (values (app-state-with-message state "place: no target panel") '())]
    [(not (eq? (panel-kind p) 'editor))
     (values (app-state-with-message state "place: target is not an editor panel") '())]
    [else
     (define-values (layout* ok?)
       (layout-panel-add-view (app-state-layout state) pid vid))
     (if (not ok?)
         (values (app-state-with-message state "place: target panel missing") '())
         (let* ([s1 (struct-copy app-state state [layout layout*])]
                [s2 (app-state-set-focus-panel s1 pid)]
                [s3 (clear-placement s2)])
           (values (struct-copy app-state s3 [message "view placed"]) '())))]))

(define (placement-commit state)
  (place-into-panel state (app-state-focus-panel-id state)))

(define (placement-cancel state)
  (define s (clear-placement state))
  (values (struct-copy app-state s [message "placement cancelled"]) '()))

;;; ════════════════ 临时表 ════════════════

(define placement-table
  (keys
   [(key 'enter)  placement-commit]
   [(key 'escape) placement-cancel]
   [(key 'left)   (placement-focus-command 'left)]
   [(key 'right)  (placement-focus-command 'right)]
   [(key 'up)     (placement-focus-command 'up)]
   [(key 'down)   (placement-focus-command 'down)]))
