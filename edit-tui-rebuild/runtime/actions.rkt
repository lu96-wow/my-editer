#lang racket

;;; edit-tui-rebuild/runtime/actions.rkt —— action 解释（唯一副作用入口）
;;;
;;; 第一版同步执行：
;;;   resource-action -> engine / 文件 IO
;;;   view-action     -> engine
;;;   quit-action     -> state.quit?
;;;
;;; action 可以产生 follow-up action（例如 save-done 后继续 quit）。

(require racket/file
         racket/path
         "../app/state.rkt"
         "../app/action.rkt"
         "../app/placement.rkt"
         "../resource/api.rkt"
         "engine.rkt")

(provide run-actions)

(define (write-file! state engine rid path)
  (define store (app-state-resources state))
  (define r (resource-ref store rid))
  (cond
    [(not r) (values (app-state-with-message state "save: resource missing") '())]
    [else
     (define did (resource-doc-id r))
     (define text (engine-doc-text engine did))
     (cond
       [(not text) (values (app-state-with-message state "save: no text") '())]
       [else
        (define ok?
          (with-handlers ([exn:fail? (λ (_) #f)])
            (display-to-file text path #:exists 'truncate)
            #t))
        (cond
          [(not ok?)
           (values (app-state-with-message state (format "save failed: ~a" path)) '())]
          [else
           (define version (engine-doc-version engine did))
           (define-values (store* more)
             (resource-save-done store rid version))
           (values (struct-copy app-state state [resources store*]) more)])])]))

(define (run-action state engine action)
  (cond
    [(resource-action? action)
     (case (resource-action-kind action)
       [(create-buffer)
        (match-define (list did name text) (resource-action-data action))
        (engine-create-buffer! engine did name text)
        (define version (engine-doc-version engine did))
        (define store* (resource-reset-version (app-state-resources state) did version))
        (values (struct-copy app-state state [resources store*]) '())]
       [(create-view)
        (match-define (list vid did) (resource-action-data action))
        (engine-create-view! engine vid did)
        (values state '())]
       [(write-file)
        (match-define (list rid path) (resource-action-data action))
        (write-file! state engine rid path)]
       [(close-resource)
        (match-define (list _rid did vids) (resource-action-data action))
        (for ([vid (in-list vids)])
          (engine-remove-view! engine vid))
        (when did
          (engine-remove-doc! engine did))
        (values state '())]
       [(quit)
        (values (struct-copy app-state state [quit? #t]) '())]
       [else (values (app-state-with-message state (format "unknown resource action: ~a" action)) '())])]
    [(open-file-action? action)
     (define path (open-file-action-path action))
     (define tables (open-file-action-tables action))
     (define text
       (with-handlers ([exn:fail? (λ (_) #f)])
         (file->string path)))
     (cond
       [(not text) (values (app-state-with-message state (format "open failed: ~a" path)) '())]
       [else
        (define name
          (let ([n (file-name-from-path path)])
            (if n (path->string n) path)))
        (define-values (store* actions)
          (resource-open (app-state-resources state)
                         #:name name
                         #:path path
                         #:text text
                         #:tables tables
                         #:focus? #f))
        (define buffer-action
          (for/first ([a (in-list actions)]
                      #:when (eq? (resource-action-kind a) 'create-buffer))
            a))
        (define view-action*
          (for/first ([a (in-list actions)]
                      #:when (eq? (resource-action-kind a) 'create-view))
            a))
        (cond
          [(or (not buffer-action) (not view-action*))
           (values (app-state-with-message state "open: malformed resource actions") '())]
          [else
           (define did (car (resource-action-data buffer-action)))
           (define vid (car (resource-action-data view-action*)))
           (define s1 (struct-copy app-state state [resources store*]))
           (define s2 (start-placement s1 vid))
           (values (run-actions s2 engine actions) '())])])]
    [(view-action? action)
     (engine-apply-view-action! engine action)
     (values state '())]
    [(quit-action? action)
     (values (struct-copy app-state state [quit? #t]) '())]
    [else
     (values (app-state-with-message state (format "unknown action: ~a" action)) '())]))

(define (run-actions state engine actions)
  (let loop ([state state] [pending actions])
    (cond
      [(null? pending) state]
      [else
       (define-values (s1 more) (run-action state engine (car pending)))
       (loop s1 (append more (cdr pending)))])))
