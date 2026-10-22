#lang racket

;;; edit-tui-rebuild/boot/actions.rkt —— action 解释（唯一副作用入口）
;;;
;;; 第一版同步执行：
;;;   resource-action -> engine / 文件 IO
;;;   view-action     -> engine
;;;   quit-action     -> state.quit?
;;;
;;; action 可以产生 follow-up action（例如 save-done 后继续 quit）。

(require racket/file
         racket/path
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/action.rkt"
         "../app/placement.rkt"
         "../app/buffer-mode.rkt"
         "../config/mode.rkt"
         "../indent/api.rkt")

(provide run-actions)

;; 从 layout 的 panel 里摘掉一个 view：保留 panel，active 落到下一个 view 或 #f。
(define (panel-without-view p vid)
  (define views (for/list ([v (in-list (panel-views p))]
                           #:unless (equal? v vid))
                 v))
  (define active
    (cond
      [(not (equal? (panel-active p) vid)) (panel-active p)]
      [(pair? views) (car views)]
      [else #f]))
  (panel-set-views p views active))

(define (detach-view-from-layout layout vid)
  (cond
    [(not layout) layout]
    [else
     (for/fold ([l layout]) ([pid (in-list (layout-panel-ids layout))])
       (define p (layout-panel l pid))
       (if (and p (memv vid (panel-views p)))
           (let-values ([(l* _ok?) (layout-panel-update l pid (λ (p) (panel-without-view p vid)))])
             l*)
           l))]))

(define (write-file! state engine rid path)
  (define store (app-state-resources state))
  (define r (resource-ref store rid))
  (cond
    [(not r) (values (app-state-with-flash state "save: resource missing") '())]
    [else
     (define did (resource-doc-id r))
     (define text (engine-doc-text engine did))
     (cond
       [(not text) (values (app-state-with-flash state "save: no text") '())]
       [else
        (define ok?
          (with-handlers ([exn:fail? (λ (_) #f)])
            (display-to-file text path #:exists 'truncate)
            #t))
        (cond
          [(not ok?)
           (values (app-state-with-flash state (format "save failed: ~a" path)) '())]
          [else
           (define version (engine-doc-version engine did))
           (define-values (store* more)
             (resource-save-done store rid version))
           ;; 边界：save-as 改扩展名后按新 path 重新绑定 mode / key table。
           (define mode (buffer-mode-for-creation path text))
           (define store**
             (resource-rebind-mode store* rid mode
                                   #:key-table (buffer-mode-key-table mode)))
           (values (struct-copy app-state state [resources store**]) more)])])]))

;; view 所属的文档 id；UI 面板（filetree / status / input）没有 resource -> #f。
(define (view-doc-id state vid)
  (define store (app-state-resources state))
  (define rid (resource-of-view store vid))
  (define r (and rid (resource-ref store rid)))
  (and r (resource-doc-id r)))

;; 文档类 view-action 之后把 resource.version 对齐 engine 里的文档版本。
;; 导航 / 滚动 / 光标不动文档，版本相同 -> 不产生 dirty。
(define (note-view-edit state engine vid)
  (define store (app-state-resources state))
  (define rid (resource-of-view store vid))
  (define r (and rid (resource-ref store rid)))
  (cond
    [(not r) state]
    [else
     (define version (engine-doc-version engine (resource-doc-id r)))
     (if (and version (not (equal? (resource-version r) version)))
         (struct-copy app-state state
                      [resources (resource-sync-version store rid version)])
         state)]))

(define (run-action state engine action)
  (cond
    [(resource-action? action)
     (case (resource-action-kind action)
       [(create-buffer)
        (match-define (list did name text) (resource-action-data action))
        (engine-create-buffer! engine did name text)
        (define version (engine-doc-version engine did))
        (define store (app-state-resources state))
        ;; action 里是 doc-id；resource-reset-version 要的是 resource-id。
        ;; 默认二者相同，但 #:doc-id 可以显式不同。
        (define rid
          (for/first ([r (in-list (resource-list store))]
                      #:when (equal? (resource-doc-id r) did))
            (resource-id r)))
        (define store* (if rid (resource-reset-version store rid version) store))
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
        ;; resource 关闭是资源级操作：先把 view 从 layout 摘掉，
        ;; 再删 engine 句柄；panel 本身保留（panel 关闭走 close-panel）。
        (define layout* (for/fold ([l (app-state-layout state)]) ([vid (in-list vids)])
                          (detach-view-from-layout l vid)))
        (define state* (struct-copy app-state state [layout layout*]))
        (for ([vid (in-list vids)])
          (engine-remove-view! engine vid))
        (when did
          (engine-remove-doc! engine did))
        (values state* '())]
       [(quit)
        (values (struct-copy app-state state [quit? #t]) '())]
       [else (values (app-state-with-flash state (format "unknown resource action: ~a" action)) '())])]
    [(open-file-action? action)
     (define path (open-file-action-path action))
     (define text
       (with-handlers ([exn:fail? (λ (_) #f)])
         (file->string path)))
     (cond
       [(not text) (values (app-state-with-flash state (format "open failed: ~a" path)) '())]
       [else
        (define name
          (let ([n (file-name-from-path path)])
            (if n (path->string n) path)))
        ;; 边界：打开文件时一次性绑定 buffer mode 与快捷键。
        (define mode (buffer-mode-for-creation path text))
        (define-values (store* actions)
          (resource-open (app-state-resources state)
                         #:name name
                         #:path path
                         #:text text
                         #:key-table (buffer-mode-key-table mode)
                         #:mode mode))
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
           (values (app-state-with-flash state "open: malformed resource actions") '())]
          [else
           (define did (car (resource-action-data buffer-action)))
           (define vid (car (resource-action-data view-action*)))
           (define s1 (struct-copy app-state state [resources store*]))
           (define s2 (start-placement s1 vid))
           (values (run-actions s2 engine actions) '())])])]
    [(newline-indent-action? action)
     (define vid (newline-indent-action-view-id action))
     (define store (app-state-resources state))
     (define rid (resource-of-view store vid))
     (define r (and rid (resource-ref store rid)))
     (define did (and r (resource-doc-id r)))
     (define text (and did (engine-doc-text engine did)))
     (cond
       [(not text)
        ;; 没有文档文本时退回普通换行。
        (values state (list (view-action 'insert vid #"\n")))]
       [else
        (define line (or (engine-view-point-line engine vid) 0))
        (define col (or (engine-view-point-column engine vid) 0))
        (define insert-text
          (newline-indent-insert-text (and r (resource-mode r)) text line col))
        (values state
                (list (view-action 'insert vid
                                   (string->bytes/utf-8 insert-text))))])]
    [(view-action? action)
     (define vid (view-action-view-id action))
     (define changes (engine-apply-view-action! engine action))
     (define state1 (note-view-edit state engine vid))
     (define did (view-doc-id state1 vid))
     (values
      (if did
          (app-state-note-doc-change state1 did
                                     (engine-doc-version engine did)
                                     changes)
          state1)
      '())]
    [(quit-action? action)
     (values (struct-copy app-state state [quit? #t]) '())]
    [else
     (values (app-state-with-flash state (format "unknown action: ~a" action)) '())]))

(define (run-actions state engine actions)
  (let loop ([state state] [pending actions])
    (cond
      [(null? pending) state]
      [else
       (define-values (s1 more) (run-action state engine (car pending)))
       (loop s1 (append more (cdr pending)))])))
