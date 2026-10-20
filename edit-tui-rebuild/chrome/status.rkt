#lang racket

;;; edit-tui-rebuild/chrome/status.rkt —— 状态栏投影
;;;
;;; 文本来自 State：
;;;   focus resource name/path
;;;   cursor line:col
;;;   dirty
;;;   pending keys
;;;   message
;;;
;;; 写入普通 core view，不另开渲染通道。

(require racket/string
         "../app/state.rkt"
         "../command/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../resource/api.rkt"
         "../runtime/engine.rkt")

(provide status-install-state
         status-line
         sync-status!)

(define (status-view state)
  (hash-ref (app-state-store state) 'status-view #f))

(define (status-install-state state view)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'status-view view)]))

(define (focus-view state)
  (define p (layout-panel (app-state-layout state)
                          (layout-focus (app-state-layout state))))
  (and p (panel-view p)))

(define (status-resource-name state)
  (define rid (app-state-focus-resource state))
  (define r (and rid (resource-ref (app-state-resources state) rid)))
  (and r (or (resource-path (app-state-resources state) rid)
             (resource-name r))))

(define (status-line state engine)
  (define vid (focus-view state))
  (define line (and vid (engine-view-point-line engine vid)))
  (define col (and vid (engine-view-point-column engine vid)))
  (define rid (app-state-focus-resource state))
  (define dirty? (and rid (resource-dirty? (app-state-resources state) rid)))
  (define pending
    (let ([p (app-state-pending state)])
      (and (pair? p) (string-join (map key->string p) " "))))
  (define parts
    (filter values
            (list (status-resource-name state)
                  (and line col (format "~a:~a" (add1 line) (add1 col)))
                  (and dirty? "*")
                  pending
                  (let ([m (app-state-message state)])
                    (and (positive? (string-length m)) m)))))
  (string-join parts "  "))

(define (sync-status! state engine)
  (define vid (status-view state))
  (cond
    [(not vid) state]
    [else
     (define text (status-line state engine))
     (define cur (or (engine-view-text engine vid) ""))
     (unless (string=? text cur)
       (engine-set-view-lines! engine vid (list text) (list 'status-bar) 0))
     state]))
