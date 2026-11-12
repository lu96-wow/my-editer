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
         "../../editor/api.rkt"
         "../../features/placement/api.rkt")

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

(define (resource-label state r)
  (define path (resource-path r))
  (if path
      (resource-display-path (state-workspace-root state) path)
      (resource-name r)))

(define (resource-rows ed state)
  (append*
   (for/list ([r (in-list (resources-list (state-resources state)))])
     (define version (editor-doc-version ed (resource-doc-id r)))
     (define dirty? (resource-dirty? r version))
     (define label (string-append (resource-label state r)
                                  (if dirty? " *" "")))
     (cons (list 'buffer (resource-id r) #f label
                 (if dirty? 'resource-pending 'resource-document))
           (for/list ([vid (in-list (resource-views r))])
             (list 'view (resource-id r) vid
                   (format "  view ~a" vid)
                   'resource-view))))))

(define (sync-resources ed state ps)
  (cond
    [(not (resources-panel-state? ps)) (values state ps)]
    [else
     (define rows (resource-rows ed state))
     (editor-set-view-content! ed
                              (resources-panel-state-view ps)
                              (map row-text rows)
                              (map row-face rows))
     (values state (struct-copy resources-panel-state ps [rows rows]))]))

(define (resources-focused? state vid)
  (eq? (editor-focus-view-id state) vid))

(define (current-row ed ps vid)
  (define rows (and (resources-panel-state? ps)
                    (resources-panel-state-rows ps)))
  (define line (editor-view-point-line ed vid))
  (and rows line (< line (length rows)) (list-ref rows line)))

(define (enter-command ed state ps vid)
  (define row (current-row ed ps vid))
  (cond
    [(not row)
     (values (state-with-flash state "resources: no line") ps '())]
    [(eq? (row-kind row) 'view)
     (define-values (s1 a1 attached?)
       (editor-focus-view-if-attached! ed state (row-view-id row)))
     (if attached?
         (values s1 ps a1)
         (values (editor-placement-start state (row-view-id row)) ps '()))]
    [else
     (define r (state-resource-for-doc state (row-resource-id row)))
     (define views (and r (resource-views r)))
     (cond
       [(pair? views)
        (define-values (s1 a1 attached?)
          (editor-focus-view-if-attached! ed state (car views)))
        (if attached?
            (values s1 ps a1)
            (values (editor-placement-start state (car views)) ps '()))]
       [else
        (values (state-with-flash state "resources: no view") ps '())])]))

(define (refresh-command ed state ps)
  (values (state-with-flash state "resources refreshed") ps '()))

(define (close-buffer-command ed state ps)
  (values state ps (list (close-buffer-action))))

(define (make-resources-plugin #:view vid)
  (make-plugin
   #:id 'resources
   #:state (resources-panel-state vid '())
   #:command-scope 'resources
   #:commands
   (keys
    [(key 'enter)
     (make-guarded-command
      #:when (λ (ed state ps) (resources-focused? state vid))
      #:run (λ (ed state ps) (enter-command ed state ps vid)))]
    [(key 'r 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (resources-focused? state vid))
      #:run refresh-command)])
   #:sync sync-resources))
