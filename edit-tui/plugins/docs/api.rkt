#lang racket

;;; edit-tui/plugins/docs/api.rkt —— docs 对其它插件的公开面
;;;
;;; docs state 只由 docs owner 更新。调用方传入当前 docs ps，拿回新的 ps；
;;; 不传整份 editor-state，也不写别的插件状态。

(require "../../editor/api.rkt"
         "../../compat/lang/racket/api.rkt"
         "../../features/open-buffers/api.rkt"
         "model.rkt")

(provide docs-show-name!
         docs-visible?)

(define (docs-visible? state ps)
  (and (docs-state? ps)
       (editor-panel-visible? state (docs-state-panel-id ps))))

(define (focus-doc-info ed state)
  (define vid (editor-focus-view-id state))
  (define did (and vid (editor-view-doc-id ed vid)))
  (define text (and did (editor-doc-text ed did)))
  (define r (and vid (state-resource-for-view state vid)))
  (values did text (and r (resource-path r))))

(define (local-preview-lines text name)
  (define snippet (and text (local-def text name)))
  (cond
    [snippet (list (format "~a" name) "── 本地定义 ──" snippet)]
    [else (list (format "~a" name) "── 文档 ──" "(loading…)")]))

(define (set-docs-lines ps lines)
  (struct-copy docs-state ps
               [lines lines]
               [faces (docs-faces lines)]
               [name (and (pair? lines) (car lines))]))

;; 立即显示本地预览；同时提交异步 docs job。
;; → (values state' docs-ps' actions)
(define (docs-show-name! ed state ps name)
  (cond
    [(not (docs-state? ps)) (values state ps '())]
    [(not (docs-visible? state ps)) (values state ps '())]
    [else
     (define-values (_did text path) (focus-doc-info ed state))
     (define ps1 (set-docs-lines ps (local-preview-lines text name)))
     (cond
       [(not text) (values state ps1 '())]
       [else
        (define-values (state2 job)
          (state-submit-job state 'docs
                                   (list name path text
                                         (editor-open-texts ed state))
                                   (list 'docs name)))
        (values state2
                (struct-copy docs-state ps1 [request-id (job-id job)])
                '())])]))
