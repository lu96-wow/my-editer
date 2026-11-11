#lang racket

;;; edit-tui-rebuild/plugins/docs/api.rkt —— docs 对其它插件的公开面
;;;
;;; completion 只调这里，不碰 docs/sync / docs/plugin 内部。

(require racket/string
         "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt"
         "model.rkt")

(provide docs-show-name!
         docs-state-of)

(define (docs-state-of state)
  (let ([st (editor-state-plugin-state state 'docs)])
    (and (docs-state? st) st)))

(define (focus-doc-info state engine)
  (define vid (editor-focus-view-id state))
  (define did (and vid (engine-view-doc-id engine vid)))
  (define text (and did (engine-doc-text engine did)))
  (define r (and vid (editor-state-resource-for-view state vid)))
  (values did text (and r (resource-path r))))

(define (local-preview-lines text name)
  (define snippet (and text (local-def text name)))
  (cond
    [snippet (list (format "~a" name) "── 本地定义 ──" snippet)]
    [else (list (format "~a" name) "── 文档 ──" "(loading…)")]))

(define (set-docs-lines state st lines)
  (editor-state-set-plugin-state
   state 'docs
   (struct-copy docs-state st
                [lines lines]
                [faces (docs-faces lines)]
                [name (and (pair? lines) (car lines))])))

;; 立即显示本地预览；同时提交异步 docs job。
(define (docs-show-name! ed state name)
  (define st (docs-state-of state))
  (cond
    [(not st) state]
    [else
     (define engine (editor-engine ed))
     (define-values (did text path) (focus-doc-info state engine))
     (define state1
       (set-docs-lines state st (local-preview-lines text name)))
     (cond
       [(not text) state1]
       [else
        (define-values (state2 job)
          (editor-state-submit-job state1 'docs
                                   (list name path text)
                                   (list 'docs name)))
        (editor-state-set-plugin-state
         state2 'docs
         (struct-copy docs-state (docs-state-of state2)
                      [request-id (job-id job)]))])]))
