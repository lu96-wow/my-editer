#lang racket

;;; edit-tui-rebuild/plugins/resources/plugin.rkt —— 资源管理面板
;;;
;;; 行投影与旧 resources 面板一致：
;;;   buffer 行（path/name + dirty *）
;;;     view 行（缩进）
;;;
;;; Enter：
;;;   buffer 行 -> 第一个 view
;;;   view 行   -> 该 view
;;; 已挂 panel：聚焦并切 active；detached：placement。

(require racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt")

(provide make-resources-plugin
         (struct-out resources-panel-state))

(struct resources-panel-state
  (view
   rows)  ; (listof (list kind resource-id view-id text face))
  #:transparent)

(define (row-kind row) (car row))
(define (row-resource-id row) (cadr row))
(define (row-view-id row) (caddr row))
(define (row-text row) (cadddr row))
(define (row-face row) (list-ref row 4))

(define (resource-label r)
  (or (resource-path r) (resource-name r)))

(define (resource-rows state engine)
  (append*
   (for/list ([r (in-list (resources-list (editor-state-resources state)))])
     (define version (engine-doc-version engine (resource-doc-id r)))
     (define dirty? (resource-dirty? r version))
     (define label (string-append (resource-label r) (if dirty? " *" "")))
     (cons (list 'buffer (resource-id r) #f label
                 (if dirty? 'resource-pending 'resource-document))
           (for/list ([vid (in-list (resource-views r))])
             (list 'view (resource-id r) vid
                   (format "  view ~a" vid)
                   'resource-view))))))

(define (sync-resources ed state)
  (define st (editor-state-plugin-state state 'resources))
  (cond
    [(not (resources-panel-state? st)) state]
    [else
     (define engine (editor-engine ed))
     (define rows (resource-rows state engine))
     (engine-set-view-content! engine
                              (resources-panel-state-view st)
                              (map row-text rows)
                              (map row-face rows))
     (editor-state-set-plugin-state
      state 'resources
      (struct-copy resources-panel-state st [rows rows]))]))

(define (resources-focused? state vid)
  (eq? (editor-focus-view-id state) vid))

(define (current-row ed state vid)
  (define st (editor-state-plugin-state state 'resources))
  (define rows (and (resources-panel-state? st)
                    (resources-panel-state-rows st)))
  (define line (engine-view-point-line (editor-engine ed) vid))
  (and rows line (< line (length rows)) (list-ref rows line)))

(define (enter-command ed state vid)
  (define row (current-row ed state vid))
  (cond
    [(not row) (values (editor-state-with-flash state "resources: no line") '())]
    [(eq? (row-kind row) 'view)
     (editor-focus-view! ed state (row-view-id row))]
    [else
     (define r (editor-state-resource-for-doc state (row-resource-id row)))
     (define views (and r (resource-views r)))
     (cond
       [(pair? views) (editor-focus-view! ed state (car views))]
       [else (values (editor-state-with-flash state "resources: no view") '())])]))

(define (refresh-command ed state)
  (values (editor-state-with-flash state "resources refreshed") '()))

(define (make-resources-plugin #:view vid)
  (make-plugin
   #:id 'resources
   #:state (resources-panel-state vid '())
   #:commands
   (keys
    [(key 'enter)
     (make-guarded-command
      #:when (λ (ed state) (resources-focused? state vid))
      #:run (λ (ed state) (enter-command ed state vid)))]
    [(key 'r 'ctrl)
     (make-guarded-command
      #:when (λ (ed state) (resources-focused? state vid))
      #:run refresh-command)])
   #:sync sync-resources))
