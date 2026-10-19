#lang racket

;;; edit-tui-rebuild/resource/model.rkt —— 资源管理（纯状态 + action 数据）
;;;
;;; resource = buffer/document + views + path + command-stack + version。
;;;
;;; 唯一分支：
;;;   path 存在   -> 可以落文件
;;;   path = #f   -> 不能落文件，保存前必须先拿 path
;;;
;;; dirty:
;;;   version != saved-version
;;;
;;; 本模块不读文件、不写文件、不碰 engine。
;;; 它只产生 action 数据：
;;;   create-buffer / create-view / write-file / close-resource / quit
;;; IO / engine 由上层解释。
;;;
;;; 输入面板只通过：
;;;   resource-prompt
;;;   resource-submit
;;;   resource-cancel
;;; 与本模块交互。

(require "../command/table.rkt")

(provide (struct-out resource)
         (struct-out resource-store)
         (struct-out resource-action)
         (struct-out resource-event)
         (struct-out prompt)
         (struct-out pending)

         resource-store-empty
         resource-ref
         resource-list
         resource-focus
         resource-set-focus

         resource-open
         resource-save
         resource-save-as
         resource-save-done
         resource-mark-edited

         resource-request-close
         resource-request-quit
         resource-prompt
         resource-submit
         resource-cancel

         resource-path
         resource-dirty?
         resource-writable?
         resource-view-ids
         resource-of-view
         resource-command-stack
         resource-set-command-stack

         resource-events
         resource-drain-events)

;;; ════════════════ 数据 ════════════════

(struct resource
  (id name doc-id views file-path binding-stack version saved-version)
  #:transparent)
;; views : (listof view-id)
;; path  : string | #f
;; version / saved-version : any/c（通常是 engine 的 opaque version token）

(struct resource-store
  (resources order focus pending prompt events
   next-resource-id next-view-id next-prompt-id)
  #:transparent)
;; resources : id -> resource
;; order     : (listof resource-id)
;; focus     : resource-id | #f
;; pending   : pending | #f
;; prompt    : prompt | #f
;; events    : (listof resource-event)

(struct resource-action (kind data) #:transparent)
;; kind : 'create-buffer | 'create-view | 'write-file
;;      | 'close-resource | 'quit

(struct resource-event (kind data) #:transparent)

(struct prompt (id kind resource-id label value choices) #:transparent)
;; kind : 'save-path | 'confirm
;; choices : (listof symbol)

(struct pending (kind ids index mode) #:transparent)
;; kind : 'quit | 'close
;; ids  : (listof resource-id)
;; mode : 'ask | 'save-all

(define resource-store-empty
  (resource-store (hash) '() #f #f #f '() 1 1 1))

;;; ════════════════ 内部 store 操作 ════════════════

(define (store-get r id) (hash-ref (resource-store-resources r) id #f))

(define (store-put r res)
  (struct-copy resource-store r
               [resources (hash-set (resource-store-resources r)
                                    (resource-id res) res)]
               [order (if (memv (resource-id res) (resource-store-order r))
                          (resource-store-order r)
                          (append (resource-store-order r) (list (resource-id res))))]))

(define (store-remove r id)
  (struct-copy resource-store r
               [resources (hash-remove (resource-store-resources r) id)]
               [order (for/list ([x (in-list (resource-store-order r))]
                                 #:unless (equal? x id))
                        x)]
               [focus (and (resource-store-focus r)
                           (not (equal? (resource-store-focus r) id))
                           (resource-store-focus r))]))

(define (store-event r kind data)
  (struct-copy resource-store r
               [events (append (resource-store-events r)
                               (list (resource-event kind data)))]))

(define (store-set-prompt r p)
  (struct-copy resource-store r [prompt p]))

(define (store-clear-prompt r)
  (struct-copy resource-store r [prompt #f]))

(define (store-set-pending r p)
  (struct-copy resource-store r [pending p]))

(define (store-clear-pending r)
  (struct-copy resource-store r [pending #f]))

(define (next-prompt-id r)
  (resource-store-next-prompt-id r))

(define (bump-prompt-id r)
  (struct-copy resource-store r
               [next-prompt-id (add1 (resource-store-next-prompt-id r))]))

(define (action kind data) (resource-action kind data))

;;; ════════════════ 读 ════════════════

(define (resource-ref store id) (store-get store id))

(define (resource-list store)
  (for/list ([id (in-list (resource-store-order store))])
    (store-get store id)))

(define (resource-focus store) (resource-store-focus store))

(define (resource-set-focus store id)
  (struct-copy resource-store store [focus id]))

(define (resource-path store id)
  (define r (resource-ref store id))
  (and r (resource-file-path r)))

(define (resource-dirty? store id)
  (define r (resource-ref store id))
  (and r (not (equal? (resource-version r) (resource-saved-version r)))))

(define (resource-writable? store id)
  (and (resource-path store id) #t))

(define (resource-view-ids store id)
  (define r (resource-ref store id))
  (if r (resource-views r) '()))

(define (resource-of-view store vid)
  (for/first ([id (in-list (resource-store-order store))]
              #:when (memv vid (resource-view-ids store id)))
    id))

(define (resource-command-stack store id)
  (define r (resource-ref store id))
  (and r (resource-binding-stack r)))

(define (resource-set-command-stack store id stack)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [else
     (store-put store (struct-copy resource r [binding-stack stack]))]))

(define (resource-events store)
  (resource-store-events store))

(define (resource-drain-events store)
  (values (struct-copy resource-store store [events '()])
          (resource-store-events store)))

;;; ════════════════ 打开 ════════════════

;; → (values store' (listof resource-action))
(define (resource-open store
                       #:name [name #f]
                       #:path [path #f]
                       #:text [text ""]
                       #:tables [tables '()]
                       #:version [version 0]
                       #:doc-id [doc-id #f]
                       #:focus? [focus? #t])
  (define rid (resource-store-next-resource-id store))
  (define vid (resource-store-next-view-id store))
  (define did (or doc-id rid))
  (define name* (or name path "*scratch*"))
  (define base (apply command-table-merge tables))
  (define stack (command-table-stack-push command-table-stack-empty base))
  (define r (resource rid name* did (list vid) path stack version version))
  (define s1 (store-put store r))
  (define s2 (struct-copy resource-store s1
                          [focus (if focus? rid (resource-store-focus s1))]
                          [next-resource-id (add1 rid)]
                          [next-view-id (add1 vid)]))
  (define s3 (store-event s2 'opened (list rid)))
  (values s3
          (list (action 'create-buffer (list did name* text))
                (action 'create-view (list vid did)))))

;;; ════════════════ 版本 ════════════════

(define (resource-mark-edited store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [else (store-event (store-put store (struct-copy resource r [version version]))
                       'edited (list id))]))

;;; ════════════════ 保存 ════════════════

;; → (values store' (listof resource-action))
(define (resource-save store id)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [(resource-file-path r)
     (values (store-clear-prompt store)
             (list (action 'write-file (list id (resource-file-path r)))))]
    [else
     (define p (prompt (next-prompt-id store) 'save-path id
                       "Save as: " "" '()))
     (values (bump-prompt-id (store-set-prompt store p)) '())]))

(define (resource-save-as store id path)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [else
     (define s1 (store-put store (struct-copy resource r [file-path path])))
     (resource-save s1 id)]))

;; 保存成功后：更新 saved-version；若在 pending 流程里，继续下一项。
(define (resource-save-done store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [else
     (define s1 (store-put store
                           (struct-copy resource r [saved-version version])))
     (define s2 (store-event s1 'saved (list id)))
     (define p (resource-store-pending s2))
     (cond
       [(and p (equal? (pending-current-id p) id))
        (advance-pending s2)]
       [else (values s2 '())])]))

;;; ════════════════ 关闭 / 退出 ════════════════

(define (dirty-ids store)
  (for/list ([id (in-list (resource-store-order store))]
             #:when (resource-dirty? store id))
    id))

(define (pending-current-id p)
  (and p
       (let ([ids (pending-ids p)] [i (pending-index p)])
         (and (< i (length ids)) (list-ref ids i)))))

(define (confirm-prompt store id)
  (define p (prompt (next-prompt-id store) 'confirm id
                    (format "Save ~a?" (resource-name* (resource-ref store id)))
                    #f '(save skip save-all skip-all cancel)))
  (bump-prompt-id (store-set-prompt store p)))

(define (resource-name* r) (resource-name r))

(define (finish-pending store)
  (define p (resource-store-pending store))
  (cond
    [(not p) (values (store-clear-prompt store) '())]
    [else
     (define s1 (store-clear-pending (store-clear-prompt store)))
     (case (pending-kind p)
       [(quit) (values (store-event s1 'quit '())
                       (list (action 'quit '())))]
       [(close)
        (define id (car (pending-ids p)))
        (define r (resource-ref store id))
        (values (store-event s1 'closed (list id))
                (list (action 'close-resource
                              (list id
                                    (and r (resource-doc-id r))
                                    (if r (resource-views r) '())))))]
       [else (values s1 '())])]))

(define (advance-pending store)
  (define p (resource-store-pending store))
  (cond
    [(not p) (values store '())]
    [else
     (define next (add1 (pending-index p)))
     (cond
       [(>= next (length (pending-ids p))) (finish-pending store)]
       [else
        (define p* (struct-copy pending p [index next]))
        (define s1 (store-set-pending store p*))
        (define id (pending-current-id p*))
        (cond
          [(eq? (pending-mode p*) 'save-all)
           (save-current-for-pending s1)]
          [else
           (values (confirm-prompt s1 id) '())])])]))

(define (save-current-for-pending store)
  (define p (resource-store-pending store))
  (define id (and p (pending-current-id p)))
  (cond
    [(not id) (values store '())]
    [else
     (define r (resource-ref store id))
     (cond
       [(not r) (advance-pending store)]
       [(resource-file-path r)
        (values (store-clear-prompt store)
                (list (action 'write-file (list id (resource-file-path r)))))]
       [else
        (define pr (prompt (next-prompt-id store) 'save-path id
                           "Save as: " "" '()))
        (values (bump-prompt-id (store-set-prompt store pr)) '())])]))

(define (resource-request-close store id)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [(resource-dirty? store id)
     (define p (pending 'close (list id) 0 'ask))
     (values (confirm-prompt (store-set-pending store p) id) '())]
    [else
     (define s1 (store-remove store id))
     (values (store-event s1 'closed (list id))
             (list (action 'close-resource
                           (list id (resource-doc-id r) (resource-views r)))))] ))

(define (resource-request-quit store)
  (define ids (dirty-ids store))
  (cond
    [(null? ids)
     (values (store-event store 'quit '())
             (list (action 'quit '())))]
    [else
     (define p (pending 'quit ids 0 'ask))
     (values (confirm-prompt (store-set-pending store p) (car ids)) '())]))

;;; ════════════════ 输入面板交互 ════════════════

(define (resource-prompt store)
  (resource-store-prompt store))

(define (resource-cancel store pid)
  (define p (resource-store-prompt store))
  (cond
    [(or (not p) (not (equal? (prompt-id p) pid))) store]
    [else
     (store-event
      (store-clear-pending (store-clear-prompt store))
      'cancelled '())]))

(define (resource-submit store pid value)
  (define p (resource-store-prompt store))
  (cond
    [(or (not p) (not (equal? (prompt-id p) pid)))
     (values store '())]
    [else
     (case (prompt-kind p)
       [(save-path)
        (define id (prompt-resource-id p))
        (resource-save-as store id value)]
       [(confirm)
        (define id (prompt-resource-id p))
        (case value
          [(cancel) (values (resource-cancel store pid) '())]
          [(skip) (advance-pending (store-clear-prompt store))]
          [(skip-all) (finish-pending store)]
          [(save) (save-current-for-pending store)]
          [(save-all)
           (define pend (resource-store-pending store))
           (define s1 (if pend
                          (store-set-pending store (struct-copy pending pend [mode 'save-all]))
                          store))
           (save-current-for-pending s1)]
          [else (values store '())])]
       [else (values store '())])]))
