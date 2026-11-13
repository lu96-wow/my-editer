#lang racket

;;; edit-tui/plugins/docs/api.rkt —— docs 对其它插件的公开面
;;;
;;; docs state 只由 docs owner 更新。调用方传入当前 docs ps，拿回新的 ps；
;;; 不传整份 editor-state，也不写别的插件状态。

(require "../../editor/api.rkt"
         "../../lang/racket/api.rkt"
         "../../features/open-buffers/api.rkt"
         "model.rkt")

(provide docs-show-name!
         docs-visible?
         docs-local-snippet)

(define (docs-visible? state ps)
  (and (docs-state? ps)
       (editor-panel-visible? state (docs-state-panel-id ps))))

(define (focus-doc-info ed state)
  (define vid (editor-focus-view-id state))
  (define did (and vid (editor-view-doc-id ed vid)))
  (define text (and did (editor-doc-text ed did)))
  (define r (and vid (state-resource-for-view state vid)))
  (values did text (and r (resource-path r))))

;; 本地定义优先查 workspace（当前 buffer + require 的本地 buffer + 其它打开 buffer）；
;; workspace 不可用时退回当前 buffer。
(define (docs-local-snippet text name [ws #f] [id #f])
  (define hit (and ws id (workspace-local-def ws id name)))
  (or (and hit (cdr hit))
      (and text (local-def text name))))

(define (local-preview-lines text name [ws #f] [id #f])
  (define snippet (docs-local-snippet text name ws id))
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
     (define-values (did text path) (focus-doc-info ed state))
     (define ws (editor-workspace ed))
     (define ps1 (set-docs-lines ps (local-preview-lines text name ws did)))
     (cond
       [(not text) (values state ps1 '())]
       [else
        (define-values (state2 job)
          (state-submit-job state 'docs
                                   (list name path text
                                         (editor-open-texts ed state)
                                         ws did)
                                   (list 'docs name)))
        (values state2
                (struct-copy docs-state ps1 [request-id (job-id job)])
                '())])]))
