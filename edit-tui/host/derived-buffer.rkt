#lang racket

;;; edit-tui/host/derived-buffer.rkt —— 动态创建 / 删除 derived doc + view
;;;
;;; derived 文档是 plugin-owned 纯内存文本：
;;;   · 不登记 resource；
;;;   · 不进 source-store / workspace；
;;;   · 无 history；内容投影走 derived-write。
;;;
;;; 这里只做 host 生命周期，不写内容。

(require "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../editor/host-api.rkt"
         "layout.rkt")

(provide create-derived-buffer!
         remove-derived-buffer!)

(define (create-derived-buffer! ed state
                                #:name name
                                #:text [text ""]
                                #:owner owner
                                #:source-doc-id [source-doc-id #f]
                                #:edit-policy [edit-policy 'intent])
  (define engine (editor-engine ed))
  (define did (state-next-view-id state))
  (define vid did)
  (engine-create-derived-buffer! engine did name text
                                 #:owner owner
                                 #:source-doc-id source-doc-id
                                 #:edit-policy edit-policy)
  (engine-create-view! engine vid did)
  (values (state-with-next-view-id state (add1 did)) did vid))

(define (remove-derived-buffer! ed state did)
  (define engine (editor-engine ed))
  (cond
    [(not (eq? (engine-doc-kind engine did) 'derived))
     (values state '())]
    [else
     (define vids (or (engine-view-ids-for-doc engine did) '()))
     (define pids
       (for/list ([vid (in-list vids)])
         (define l (state-layout state))
         (and l (layout-panel-for-view l vid))))
     (define state*
       (for/fold ([s state]) ([vid (in-list vids)])
         (editor-detach-view! s vid)))
     (engine-remove-doc! engine did)
     ;; split 出来的 mirror panel 只含 mirror view；摘掉后若为空就删 panel。
     (define state**
       (for/fold ([s state*]) ([pid (in-list pids)])
         (define l (state-layout s))
         (define panel (and l pid (layout-panel l pid)))
         (cond
           [(and panel (null? (p:panel-views panel)))
            (define-values (l* ok?)
              (layout-panel-remove l pid #:config (state-layout-config s)))
            (if ok? (state-with-layout s l*) s)]
           [else s])))
     (values state** '())]))
