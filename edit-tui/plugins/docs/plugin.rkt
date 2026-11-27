#lang racket

;;; edit-tui/plugins/docs/plugin.rkt —— docs 面板 + 异步文档服务

(require racket/match
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "../../lang/racket/api.rkt"
         (only-in "../../lang/c/api.rkt"
                  c-docs-lines c-identifier-at)
         "model.rkt"
         "api.rkt")

(provide make-docs-plugin)

;; binding 的 car 是路径时表示名字来自本地文件；此时没有 xref 文档可查，
;; 本地定义由 workspace / 当前 buffer 提供。
(define (local-binding? binding)
  (and binding
       (let ([m (car binding)]) (or (path? m) (string? m)))))

;; 查文档用的候选模块：binding 指出的模块排最前，其余来自 #lang + require。
;; 启发式反查可能漏判（binding = #f），此时让 docs-for 逐个模块试，
;; 不能直接放弃库文档。
(define (doc-modules ctx binding)
  (define base-dir (completion-context-base-dir ctx))
  (define parsed
    (with-handlers ([exn:fail? (λ (_) '())])
      (requires-of-forms (completion-context-lang ctx)
                         (completion-context-forms ctx)
                         #:base-dir base-dir)))
  (define mods (if (null? parsed) '(racket/base) parsed))
  (cond
    [(not binding) mods]
    [else
     (define bm (car binding))
     (cons bm (remove bm mods))]))

(define (docs-service payload)
  (match-define (list name path text open ws id mode) payload)
  (if (eq? mode 'c)
      (c-docs-lines name #:text text)
      (let* ([ctx (and text
                       (make-completion-context path text
                                                #:open open
                                                #:workspace ws
                                                #:id id))]
             [binding
              (and ctx
                   (with-handlers ([exn:fail? (λ (_) #f)])
                     (spec-binding-of name
                                      (completion-context-specs ctx)
                                      (completion-context-base-dir ctx)
                                      (completion-context-open ctx))))]
             ;; prefix-in / rename-in 后文档要用**原名**查；本地定义也是按原名
             ;; 写在源文件里的。
             [lookup-name (if binding (format "~a" (cadr binding)) name)]
             [local (docs-local-snippet text lookup-name ws id mode)]
             [mods (cond
                     [(not ctx) '()]
                     [(local-binding? binding) '()]
                     [else (doc-modules ctx binding)])]
             [d (and (pair? mods)
                     (with-handlers ([exn:fail? (λ (_) #f)])
                       (docs-for lookup-name #:modules mods)))])
        (append
         (list (format "~a" name))
         (if local
             (cons "── 本地定义 ──"
                   (string-split local "\n" #:trim? #f))
             '())
         (if d
             (cons "── 文档 ──"
                   (string-split (string-trim (doc->text d)) "\n"))
             '())))))

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
        (define ps*
          (struct-copy docs-state ps
                       [lines result]
                       [faces (docs-faces result)]
                       [request-id #f]))
        (editor-set-view-cursor! ed (docs-state-view ps*) 0 #:column 0)
        (editor-ensure! ed state (docs-state-view ps*))
        (values state ps* '())]
       [else
        (values state (struct-copy docs-state ps [request-id #f]) '())])]))

(define (sync-docs! ed state ps)
  (cond
    [(not (docs-state? ps)) (values state ps)]
    [(not (docs-visible? state ps)) (values state ps)]
    [else
     (editor-set-view-content! ed
                              (docs-state-view ps)
                              (docs-state-lines ps)
                              (docs-state-faces ps))
     (values state ps)]))

(define (toggle-command ed state ps)
  (define-values (state* actions) (editor-toggle-panel! ed state 'docs))
  (values state* ps actions))

(define (show-identifier-command ed state ps)
  (define vid (editor-focus-view-id state))
  (define text (and vid (editor-view-text ed vid)))
  (define line (and vid (editor-view-point-line ed vid)))
  (define col (and vid (editor-view-point-column ed vid)))
  (define did (and vid (editor-view-doc-id ed vid)))
  (define mode (and did (state-doc-mode state did)))
  (define name
    (and text line col
         (case mode
           [(c) (c-identifier-at text line col)]
           [else (identifier-at text line col)])))
  (cond
    [name (docs-show-name! ed state ps name)]
    [else (values (state-with-flash state "docs: no identifier") ps '())]))

(define (make-docs-plugin #:view vid #:panel-id [panel-id 'docs])
  (make-plugin
   #:id 'docs
   #:state (empty-docs-state vid panel-id)
   #:view-scopes (hash vid 'docs)
   #:sync sync-docs!
   #:services (list (service 'docs docs-service))
   #:handle-job handle-docs-job
   #:commands
   (keys
    [(key 'x 'ctrl) (key 'd) toggle-command]
    [(key 'd 'alt) show-identifier-command])))
