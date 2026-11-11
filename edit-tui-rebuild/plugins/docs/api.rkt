#lang racket

;;; edit-tui-rebuild/plugins/docs/api.rkt —— docs 对其它插件的公开面
;;;
;;; docs state 只由 docs owner 更新。调用方传入当前 docs ps，拿回新的 ps；
;;; 不传整份 editor-state，也不写别的插件状态。

(require "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt"
         "model.rkt")

(provide docs-show-name!)

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
    [else
     (define engine (editor-engine ed))
     (define-values (_did text path) (focus-doc-info state engine))
     (define ps1 (set-docs-lines ps (local-preview-lines text name)))
     (cond
       [(not text) (values state ps1 '())]
       [else
        (define-values (state2 job)
          (editor-state-submit-job state 'docs
                                   (list name path text)
                                   (list 'docs name)))
        (values state2
                (struct-copy docs-state ps1 [request-id (job-id job)])
                '())])]))
