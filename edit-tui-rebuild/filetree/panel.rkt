#lang racket

;;; edit-tui-rebuild/filetree/panel.rkt —— 文件树面板同步
;;;
;;; 每帧：
;;;   resource paths -> opened 集合
;;;   dir-entries + expanded -> 行
;;;   rows / cursor 写回 app-state.store['filetree]
;;;   同时把文本 / face / 光标写进 core view

(require "../app/state.rkt"
         "../resource/api.rkt"
         "../runtime/engine.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt")

(provide sync-filetree!)

(define (filetree-state state)
  (hash-ref (app-state-store state) 'filetree #f))

(define (set-filetree-state state f)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]))

(define (opened-paths state)
  (for/fold ([h (hash)]) ([r (in-list (resource-list (app-state-resources state)))])
    (define p (resource-path (app-state-resources state) (resource-id r)))
    (if p
        (hash-set h (filetree-normalize-path p) #t)
        h)))

(define (sync-filetree! state engine)
  (define f (filetree-state state))
  (cond
    [(or (not f) (not (filetree-view f))) state]
    [else
     (define rows
       (filetree-lines (app-state-root state)
                       (filetree-expanded f)
                       (opened-paths state)
                       dir-entries))
     (define n (length rows))
     (define cursor
       (cond [(zero? n) 0]
             [else (max 0 (min (filetree-cursor f) (sub1 n)))]))
     (define f* (filetree-set-rows (filetree-set-line f cursor) rows))
     (define state* (set-filetree-state state f*))
     (engine-set-view-lines! engine (filetree-view f*)
                             (map filetree-line-text rows)
                             (map filetree-line-face rows)
                             cursor)
     state*]))
