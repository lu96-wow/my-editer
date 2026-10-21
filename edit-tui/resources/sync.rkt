#lang racket

;;; edit-tui/resources/sync.rkt —— 资源管理面板同步

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "slice.rkt"
         "model.rkt"
         "lines.rkt")

(provide sync-resource-panel!)

(define (make-resource-panel-sync-key vid revision line col)
  (list vid revision line col))

(define (sync-resource-panel! state engine)
  (define rp (resource-panel-of state))
  (cond
    [(or (not rp) (not (resource-panel-view rp))) state]
    [else
     (define store (app-state-resources state))
     (define revision (resource-revision store))
     (define vid (resource-panel-view rp))
     (define-values (line col)
       (if (resource-panel-cursor-dirty? rp)
           (values (resource-panel-cursor rp) 0)
           (values (or (engine-view-point-line engine vid) 0)
                   (or (engine-view-point-column engine vid) 0))))
     (define key (make-resource-panel-sync-key vid revision line col))
     (cond
       [(equal? key (resource-panel-sync-key rp)) state]
       [else
        (define rows
          (if (equal? revision (resource-panel-revision rp))
              (resource-panel-rows rp)
              (resource-panel-lines store)))
        (engine-set-view-lines! engine vid
                                (map resource-line-text rows)
                                (map resource-line-face rows)
                                line
                                #:column col)
        (define actual-line (or (engine-view-point-line engine vid) line))
        (define actual-col (or (engine-view-point-column engine vid) col))
        (define actual-key
          (make-resource-panel-sync-key vid revision actual-line actual-col))
        (resource-panel-put state
                            (resource-panel-set-sync rp revision rows
                                                     actual-key actual-line))])]))
