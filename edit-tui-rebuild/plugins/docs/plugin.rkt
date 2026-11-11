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

(define (handle-docs-job ed state ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'docs)) state]
    [else
     (define st (docs-state-of state))
     (define result (job-result-event-result ev))
     (cond
       [(not st) state]
       [(not (equal? (docs-state-request-id st) (job-result-event-id ev))) state]
       [(job-error? result)
        (editor-state-set-plugin-state
         state 'docs (struct-copy docs-state st [request-id #f]))]
       [(and (list? result) (andmap string? result))
        (editor-state-set-plugin-state
         state 'docs
         (struct-copy docs-state st
                      [lines result]
                      [faces (docs-faces result)]
                      [request-id #f]))]
       [else
        (editor-state-set-plugin-state
         state 'docs (struct-copy docs-state st [request-id #f]))])]))

(define (sync-docs! ed state)
  (define st (docs-state-of state))
  (cond
    [(not st) state]
    [else
     (engine-set-view-content! (editor-engine ed)
                              (docs-state-view st)
                              (docs-state-lines st)
                              (docs-state-faces st))
     state]))

(define (toggle-command ed state)
  (editor-toggle-panel! ed state 'docs))

(define (show-identifier-command ed state)
  (define engine (editor-engine ed))
  (define vid (editor-focus-view-id state))
  (define text (and vid (engine-view-text engine vid)))
  (define line (and vid (engine-view-point-line engine vid)))
  (define col (and vid (engine-view-point-column engine vid)))
  (define name (and text line col (identifier-at text line col)))
  (cond
    [name (values (docs-show-name! ed state name) '())]
    [else (values (editor-state-with-flash state "docs: no identifier") '())]))

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
