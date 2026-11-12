#lang racket

;;; edit-tui-rebuild/host/close.rkt —— editor tab 切换 / 关闭 buffer
;;;
;;; 关闭 buffer = 从所有 layout panel 摘掉它的 views，删 engine doc，删 resource。
;;; 关闭 panel（C-d）仍然只摘 panel，view / resource 保留，之后可 placement。

(require "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../editor/engine/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt"
         "../editor/layout.rkt"
         "../features/input/api.rkt")

(provide editor-close-buffer-command
         editor-close-resource!)

(define (panel-without-view p vid)
  (define views (for/list ([v (in-list (p:panel-views p))]
                           #:unless (memv v (list vid)))
                 v))
  (define active
    (cond
      [(not (equal? (p:panel-active p) vid)) (p:panel-active p)]
      [(pair? views) (car views)]
      [else #f]))
  (p:panel-set-views p views active))

(define (detach-view-from-layout layout vid)
  (for/fold ([l layout]) ([pid (in-list (layout-panel-ids layout))])
    (define p (layout-panel l pid))
    (if (and p (memv vid (p:panel-views p)))
        (let-values ([(l* _ok?) (layout-panel-update l pid (λ (p) (panel-without-view p vid)))])
          l*)
        l)))

(define (editor-close-resource! ed state rid)
  (define r (resources-find-doc (state-resources state) rid))
  (cond
    [(not r) (values state '())]
    [else
     (define views (resource-views r))
     (define l (for/fold ([l (state-layout state)]) ([vid (in-list views)])
                 (detach-view-from-layout l vid)))
     (engine-remove-doc! (editor-engine ed) (resource-doc-id r))
     (define state*
       (state-with-flash
        (state-with-resources
         (state-with-layout state l)
         (resources-remove (state-resources state) rid))
        (format "closed: ~a" (or (resource-path r) (resource-name r)))))
     (values state* '())]))

;; 关闭当前 focus resource：dirty -> close-confirm；clean -> 直接关闭。
(define (editor-close-buffer-command ed state)
  (define r (and (editor-focus-view-id state)
                 (state-resource-for-view state (editor-focus-view-id state))))
  (cond
    [(not r) (values (state-with-flash state "close: no resource") '())]
    [(resource-dirty? r (engine-doc-version (editor-engine ed) (resource-doc-id r)))
     (values (editor-input-open state 'close-confirm
                                (format "Close ~a? (y/n) "
                                        (or (resource-path r) (resource-name r)))
                                (list 'close (resource-id r)))
             '())]
    [else (editor-close-resource! ed state (resource-id r))]))
