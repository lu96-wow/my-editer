#lang racket

;;; edit-tui-rebuild/features/sidebar/sidebar.rkt —— sidebar chrome 操作
;;;
;;; sidebar 是 app/chrome 行为，不是通用 editor layout：
;;;   · 同一 sidebar panel 内切 tab
;;;   · 显 / 隐 sidebar（保持 fixed size / ratio + min clamp）

(require "../../core/layout/api.rkt"
         (prefix-in p: "../../core/panel/api.rkt")
         "../../editor/api.rkt")

(provide editor-cycle-sidebar-view!
         editor-toggle-sidebar!)

(define (sidebar-panel-id state)
  (define l (state-layout state))
  (define focus (and l (layout-focus l)))
  (define fp (and focus (layout-panel l focus)))
  (cond
    [(and fp (eq? (p:panel-kind fp) 'sidebar)) focus]
    [l (for/first ([pid (in-list (layout-panel-ids l))]
                   #:when (eq? (p:panel-kind (layout-panel l pid)) 'sidebar))
         pid)]
    [else #f]))

(define (editor-cycle-sidebar-view! ed state)
  (define l (state-layout state))
  (define pid (sidebar-panel-id state))
  (cond
    [(not pid) (values (state-with-flash state "sidebar: no panel") '())]
    [else
     (define-values (l* ok?) (layout-panel-cycle-active-view l pid))
     (cond
       [ok? (values (state-with-layout state l*) '())]
       [else (values (state-with-flash state "sidebar: only one view") '())])]))

(define (editor-toggle-sidebar! ed state)
  (define l (state-layout state))
  (define area (state-area state))
  (define pid (sidebar-panel-id state))
  (cond
    [(or (not l) (not area) (not pid))
     (values (state-with-flash state "sidebar: no panel") '())]
    [else
     (define visible? (layout-panel-visible? l pid))
     (define-values (l* ok?)
       (if visible?
           (layout-panel-hide l area pid #:config (state-layout-config state))
           (layout-panel-show l area pid #:config (state-layout-config state))))
     (if ok?
         (values (state-with-layout state l*) '())
         (values (state-with-flash state "sidebar toggle failed") '()))]))
