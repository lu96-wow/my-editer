#lang racket

;;; edit-tui/host/close.rkt —— editor tab 切换 / 关闭 buffer
;;;
;;; 关闭 buffer = 从所有 layout panel 摘掉它的 views，删 engine doc，删 resource。
;;; 关闭 panel（C-d）仍然只摘 panel，view / resource 保留，之后可 placement。

(require "layout.rkt"
         "bilingual.rkt"
         "../editor/engine/read.rkt"
         "../editor/engine/lifecycle.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt"
         "../editor/layout.rkt"
         "../features/input/api.rkt")

(provide editor-close-buffer-command
         editor-close-resource!)

(define (editor-close-resource! ed state rid)
  (define r (resources-find-doc (state-resources state) rid))
  (cond
    [(not r) (values state '())]
    [else
     (define views (resource-views r))
     (define state0
       (for/fold ([s state]) ([vid (in-list views)])
         (editor-detach-view! s vid)))
     (engine-remove-doc! (editor-engine ed) (resource-doc-id r))
     (define state*
       (state-with-flash
        (state-with-resources state0
                              (resources-remove (state-resources state0) rid))
        (format "closed: ~a" (or (resource-path r) (resource-name r)))))
     (bilingual-close-pair-for-source! ed state* (resource-doc-id r))]))

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
