#lang racket

;;; edit-tui-rebuild/app/placement.rkt —— 把 view 放进目标 panel
;;;
;;; 流程：
;;;   filetree Enter on file
;;;     -> start-placement view-id
;;;     -> push placement-table
;;;   user click target panel / 切换焦点后 Enter
;;;     -> place-into-panel
;;;   Esc -> placement-cancel

(require "../command/api.rkt"
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

(define (start-placement state vid)
  (unless vid (error 'start-placement "view-id 不能是 #f"))
  (struct-copy app-state state
               [placement vid]
               [overlays (cons placement-table (app-state-overlays state))]))

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
   [(key 'enter) placement-commit]
   [(key 'escape) placement-cancel]))
