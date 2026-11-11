#lang racket

;;; edit-tui-rebuild/plugins/docs/plugin.rkt —— docs 面板 + 异步文档服务

(require racket/match
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt"
         "model.rkt"
         "api.rkt")

(provide make-docs-plugin)

(define (docs-service payload)
  (match-define (list name path text) payload)
  (define local (and text (local-def text name)))
  (define ctx (and text (make-completion-context path text)))
  (define binding
    (and ctx
         (with-handlers ([exn:fail? (λ (_) #f)])
           (spec-binding-of name
                            (completion-context-specs ctx)
                            (completion-context-base-dir ctx)
                            (completion-context-open ctx)))))
  (define d
    (and binding
         (with-handlers ([exn:fail? (λ (_) #f)])
           (docs-for name #:modules (list (car binding))))))
  (append
   (list (format "~a" name))
   (if local (list "── 本地定义 ──" local) '())
   (if d
       (cons "── 文档 ──"
             (string-split (string-trim (doc->text d)) "\n"))
       '())))

(define (handle-docs-job ed state ps ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'docs)) (values state ps '())]
    [(not (docs-state? ps)) (values state ps '())]
    [else
     (define result (job-result-event-result ev))
     (cond
       [(not (equal? (docs-state-request-id ps) (job-result-event-id ev)))
        (values state ps '())]
       [(job-error? result)
        (values state (struct-copy docs-state ps [request-id #f]) '())]
       [(and (list? result) (andmap string? result))
        (values state
                (struct-copy docs-state ps
                             [lines result]
                             [faces (docs-faces result)]
                             [request-id #f])
                '())]
       [else
        (values state (struct-copy docs-state ps [request-id #f]) '())])]))

(define (sync-docs! ed state ps)
  (cond
    [(not (docs-state? ps)) (values state ps)]
    [else
     (engine-set-view-content! (editor-engine ed)
                              (docs-state-view ps)
                              (docs-state-lines ps)
                              (docs-state-faces ps))
     (values state ps)]))

(define (toggle-command ed state ps)
  (define-values (state* actions) (editor-toggle-panel! ed state 'docs))
  (values state* ps actions))

(define (show-identifier-command ed state ps)
  (define engine (editor-engine ed))
  (define vid (editor-focus-view-id state))
  (define text (and vid (engine-view-text engine vid)))
  (define line (and vid (engine-view-point-line engine vid)))
  (define col (and vid (engine-view-point-column engine vid)))
  (define name (and text line col (identifier-at text line col)))
  (cond
    [name (docs-show-name! ed state ps name)]
    [else (values (editor-state-with-flash state "docs: no identifier") ps '())]))

(define (make-docs-plugin #:view vid #:panel-id [panel-id 'docs])
  (make-plugin
   #:id 'docs
   #:state (empty-docs-state vid panel-id)
   #:sync sync-docs!
   #:services (list (service 'docs docs-service))
   #:handle-job handle-docs-job
   #:commands
   (keys
    [(key 'x 'ctrl) (key 'd) toggle-command]
    [(key 'd 'alt) show-identifier-command])))
