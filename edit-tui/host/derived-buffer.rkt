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
     (define locs
       (for/list ([vid (in-list vids)])
         (editor-view-location state vid)))
     (define state*
       (for/fold ([s state]) ([vid (in-list vids)])
         (editor-detach-view! s vid)))
     (engine-remove-doc! engine did)
     ;; split 出来的 mirror panel 只含 mirror view；摘掉后若为空就删 panel。
     (define state**
       (for/fold ([s state*]) ([loc (in-list locs)] #:when loc)
         (define aid (view-location-area-id loc))
         (define pid (view-location-panel-id loc))
         (define l (editor-area-layout-for s aid))
         (define panel (and l pid (layout-panel l pid)))
         (cond
           ;; 最后一个 editor panel 不能从 area 里删掉：它同时是 slot 的边界 leaf。
           ;; 内容已经 detach，保留空 panel 即可。没有启用 area 的旧 state 保持
           ;; 原来的“空 panel 就删”行为。
           [(and (or (state-area-slot s)
                     (not (equal? aid (state-current-area s))))
                 (<= (editor-area-panel-count s aid) 1))
            s]
           [(and panel (null? (p:panel-views panel)))
            (define-values (l* ok?)
              (layout-panel-remove l pid #:config (state-layout-config s)))
            (if ok? (editor-with-area-layout s aid l*) s)]
           [else s])))
     (values state** '())]))
