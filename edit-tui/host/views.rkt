#lang racket

;;; edit-tui/host/views.rkt —— view 管理宿主操作
;;;
;;; 创建：给 resource 新建 engine view，并尽量作为 tab 挂到已有 view 所在 panel；
;;;       没有已挂载的兄弟 view 时保持 detached，之后可由 placement 放入空 panel。
;;; 删除：从所有 area / panel 摘掉，移出 resource.views，再删 engine view。
;;;
;;; view 管理面板只发 action；engine / layout 写回都在这里。

(require "../core/layout/api.rkt"
         "../editor/host-api.rkt"
         "../editor/resource.rkt"
         "../editor/state.rkt"
         "layout.rkt")

(provide editor-create-view-for-resource!
         editor-delete-view!)

(define (resource-by-id state rid)
  (for/first ([r (in-list (resources-list (state-resources state)))]
              #:when (equal? (resource-id r) rid))
    r))

(define (attached-view-for-resource state r)
  (for/first ([vid (in-list (resource-views r))]
              #:when (editor-view-location state vid))
    vid))

;; 新建 view 时尽量留在原 panel，但不要抢走当前 focus（通常 focus 在 views 面板）。
(define (restore-focus state pid)
  (define l (state-layout state))
  (cond
    [(and l pid (layout-panel l pid))
     (state-with-layout state (layout-set-focus l pid))]
    [else state]))

;; → (values state' actions)
(define (editor-create-view-for-resource! ed state rid)
  (define r (resource-by-id state rid))
  (cond
    [(not r)
     (values (state-with-flash state "view: resource not found") '())]
    [else
     (define engine (editor-engine ed))
     (define did (resource-doc-id r))
     (define nvid (state-next-view-id state))
     (define prev-focus (editor-focus-panel-id state))
     (define anchor (attached-view-for-resource state r))
     (cond
       [anchor (void (engine-create-view-from-view! engine nvid anchor))]
       [else (void (engine-create-view! engine nvid did))])
     (define rs (resources-add-view (state-resources state) rid nvid))
     (define state1
       (state-with-next-view-id (state-with-resources state rs) (add1 nvid)))
     (cond
       [anchor
        (define-values (state2 attached?)
          (editor-attach-view-as-tab! state1 anchor nvid))
        (define state3 (restore-focus state2 prev-focus))
        (values (state-with-flash
                 state3
                 (if attached?
                     (format "view ~a created" nvid)
                     (format "view ~a created (detached)" nvid)))
                '())]
       [else
        (values (state-with-flash
                 state1
                 (format "view ~a created (detached)" nvid))
                '())])]))

;; → (values state' actions)
(define (editor-delete-view! ed state vid)
  (define r (resources-find-view (state-resources state) vid))
  (cond
    [(not r)
     (values (state-with-flash state "view: not found") '())]
    [else
     ;; detach 从当前 frame + 所有 inactive area 摘掉。
     (define state1 (editor-detach-view! state vid))
     (define views
       (for/list ([v (in-list (resource-views r))]
                  #:unless (equal? v vid))
         v))
     (define rs (resources-set-views (state-resources state1) (resource-id r) views))
     (engine-remove-view! (editor-engine ed) vid)
     (values (state-with-flash
              (state-with-resources state1 rs)
              (format "view ~a deleted" vid))
             '())]))
