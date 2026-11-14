#lang racket

;;; edit-tui/host/layout.rkt —— host 侧 view / panel 挂载
;;;
;;; editor/layout.rkt 是通用布局操作面；这里补 host 装配需要的能力：
;;;   · 从 layout 摘掉一个 view（不删 engine view）
;;;   · 把已有 view 作为 tab 加进某个 panel
;;;
;;; 纯布局仍是 core/layout 的值；这里只负责 state 写回。
;;; 多编辑区下 view 可能挂在 inactive area：detach 查全部 area，
;;; attach 先切到 anchor 所在 area，再把 view 从原位置摘掉。

(require "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../editor/host-api.rkt")

(provide editor-detach-view!
         editor-attach-view-as-tab!
         editor-attach-view-in-new-split!
         editor-view-panel-id
         editor-set-panel-face!)

(define (editor-view-panel-id state vid)
  (define loc (editor-view-location state vid))
  (and loc (view-location-panel-id loc)))

(define (editor-set-panel-face! state pid face)
  (define l (state-layout state))
  (cond
    [(or (not l) (not pid)) state]
    [else
     (define-values (l* ok?)
       (layout-panel-update l pid (lambda (p) (p:panel-set-face p face))))
     (if ok? (state-with-layout state l*) state)]))

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

(define (layout-without-view l vid)
  (for/fold ([l l]) ([pid (in-list (layout-panel-ids l))])
    (define p (layout-panel l pid))
    (if (and p (memv vid (p:panel-views p)))
        (let-values ([(l* _ok?) (layout-panel-update l pid
                                                     (lambda (p)
                                                       (panel-without-view p vid)))])
          l*)
        l)))

;; 从当前 frame 和所有 inactive area 摘掉 view。
(define (editor-detach-view! state vid)
  (define state1
    (if (editor-view-in-current-area? state vid)
        (state-with-layout state (layout-without-view (state-layout state) vid))
        state))
  (for/fold ([s state1])
            ([area-id (in-list (hash-keys (state-areas state1)))])
    (cond
      [(editor-view-panel-id-in-area s area-id vid)
       (define l (editor-layout-for-area s area-id))
       (editor-with-area-layout s area-id (layout-without-view l vid))]
      [else s])))

;; attach 的公共前置：
;;   1. 找到 anchor 所在 area，必要时切过去；
;;   2. 把 new-vid 从原位置摘掉（保证一 view 一 panel）。
;; → (values state' anchor-panel-id) | (values state #f)
(define (prepare-attach-target state anchor-vid new-vid)
  (define anchor-loc (editor-view-location state anchor-vid))
  (cond
    [(or (not anchor-loc) (equal? anchor-vid new-vid))
     (values state #f)]
    [else
     (define anchor-area (view-location-area-id anchor-loc))
     (define state0 (editor-switch-area state anchor-area))
     (define state1 (editor-detach-view! state0 new-vid))
     (define l (state-layout state1))
     (values state1 (and l anchor-vid (layout-panel-for-view l anchor-vid)))]))

;; anchor-vid 所在 panel 加 new-vid，并设为 active / focus。
(define (editor-attach-view-as-tab! state anchor-vid new-vid)
  (define-values (state1 pid) (prepare-attach-target state anchor-vid new-vid))
  (cond
    [(not pid) (values state1 #f)]
    [else
     (define l (state-layout state1))
     (define-values (l* ok?) (layout-panel-add-view l pid new-vid))
     (cond
       [(not ok?) (values state1 #f)]
       [else
        (define-values (l** active?) (layout-panel-set-active-view l* pid new-vid))
        (define l*** (layout-set-focus (if active? l** l*) pid))
        (values (state-with-layout state1 l***) #t)])]))

;; 在 anchor-vid 所在 panel 旁边新建同 kind panel，把 new-vid 放进去。
;; 返回 ok? = #f 时调用方可以退回 attach-as-tab。
(define (editor-attach-view-in-new-split! state anchor-vid new-vid dir)
  (define-values (state1 pid) (prepare-attach-target state anchor-vid new-vid))
  (cond
    [(not pid) (values state1 #f)]
    [else
     (define l (state-layout state1))
     (define new-pid (state-next-panel-id state1))
     (define-values (l1 ok?)
       (layout-split l pid dir new-pid #:config (state-layout-config state1)))
     (cond
       [(not ok?) (values state1 #f)]
       [else
        (define-values (l2 added?) (layout-panel-add-view l1 new-pid new-vid))
        (cond
          [(not added?) (values state1 #f)]
          [else
           (define-values (l3 active?)
             (layout-panel-set-active-view l2 new-pid new-vid))
           (define l4 (layout-set-focus (if active? l3 l2) new-pid))
           (values (state-with-next-panel-id
                    (state-with-layout state1 l4)
                    (add1 new-pid))
                   #t)])])]))
