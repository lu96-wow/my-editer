#lang racket

;;; edit-tui/resources/commands.rkt —— 资源管理面板命令 / 安装
;;;
;;; Enter:
;;;   buffer 行 -> 该 resource 的第一个 view
;;;   view 行   -> 该 view
;;; 已挂在 panel：聚焦 panel 并把 active view 切过去；
;;; detached：进入 placement。

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/placement.rkt"
         "slice.rkt"
         "model.rkt"
         "lines.rkt")

(provide resource-panel-install-state
         resource-panel-enter-command
         resource-panel-refresh-command)

(define (resource-panel-current-line state)
  (define rp (resource-panel-of state))
  (resource-panel-line-at (resource-panel-rows rp)
                          (resource-panel-cursor rp)))

(define (focus-resource-view state vid)
  (define layout (app-state-layout state))
  (define pid (and layout (layout-panel-for-view layout vid)))
  (cond
    [(not pid) (values (start-placement state vid) '())]
    [else
     (define-values (layout* ok?)
       (layout-panel-set-active-view layout pid vid))
     (define state* (if ok?
                        (struct-copy app-state state [layout layout*])
                        state))
     (values (app-state-set-focus-panel state* pid) '())]))

(define (resource-panel-enter-command state)
  (define line (resource-panel-current-line state))
  (cond
    [(not line)
     (values (app-state-with-flash state "resources: no line") '())]
    [(eq? (resource-line-kind line) 'view)
     (focus-resource-view state (resource-line-view-id line))]
    [else
     (define store (app-state-resources state))
     (define rid (resource-line-resource-id line))
     (define vids (resource-view-ids store rid))
     (cond
       [(pair? vids) (focus-resource-view state (car vids))]
       [else (values (app-state-with-flash state "resources: no view") '())])]))

(define (resource-panel-refresh-command state)
  (values (resource-panel-put state
                              (resource-panel-invalidate (resource-panel-of state)))
          '()))

(define (resource-panel-install-state state view
                                      #:panel-stack panel-stack)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'resource-panel
                                (resource-panel-set-view
                                 (empty-resource-panel) view))]
               [panel-stacks (hash-set (app-state-panel-stacks state)
                                       view panel-stack)]))
