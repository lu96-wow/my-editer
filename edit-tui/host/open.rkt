#lang racket

;;; edit-tui/host/open.rkt —— 打开文件 / 去重 / placement
;;;
;;; 对齐旧行为，并支持多编辑区：
;;;   已打开且 view 挂在任意 area -> 切到该 area 并聚焦已有 panel
;;;   已打开但 detached          -> placement（不新建 doc）
;;;   未打开                     -> 读文件 / 新建 doc+view / 加 resource / placement
;;;
;;; IO 只在 host 解释 open-file-action 时发生。

(require racket/file
         racket/path
         "../editor/engine/read.rkt"
         "../editor/engine/lifecycle.rkt"
         "../editor/error.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt"
         "../editor/mode.rkt"
         "../editor/layout.rkt"
         "../editor/area.rkt"
         "../features/placement/api.rkt"
         "keymap.rkt")

(provide editor-open-file!
         editor-focus-view!)

;; 优先当前 area 的 view；否则任意 area 里已附着的 view；都没有返回 #f。
(define (resource-attached-view state r)
  (define views (resource-views r))
  (or (for/first ([vid (in-list views)]
                  #:when (editor-view-in-current-area? state vid))
        vid)
      (for/first ([vid (in-list views)]
                  #:when (editor-view-location state vid))
        vid)))

(define (focus-existing-resource ed state r)
  (define vid (resource-attached-view state r))
  (cond
    [(not vid)
     (define first-vid (and (pair? (resource-views r)) (car (resource-views r))))
     (if first-vid
         (values (editor-placement-start state first-vid) '())
         (values (state-with-flash state "open: resource has no view") '()))]
    [else
     (define-values (state* actions attached?)
       (editor-focus-view-if-attached! ed state vid))
     (if attached?
         (values state* actions)
         (values (editor-placement-start state* vid) actions))]))

;; 聚焦一个已经存在的 view：挂在 panel 上就切 active + 聚焦；detached 就 placement。
(define (editor-focus-view! ed state vid)
  (cond
    [(not vid) (values (state-with-flash state "focus-view: no view") '())]
    [else
     (define-values (state* actions attached?)
       (editor-focus-view-if-attached! ed state vid))
     (if attached?
         (values state* actions)
         (values (editor-placement-start state* vid) actions))]))

(define (editor-open-file! ed state path)
  (define path* (resource-normalize-path path))
  (define existing (resources-find-path (state-resources state) path*))
  (cond
    [existing (focus-existing-resource ed state existing)]
    [else
     (define-values (text err)
       (with-handlers ([exn:fail? (λ (e) (values #f e))])
         (values (file->string path*) #f)))
     (cond
       [err
        (values
         (state-record-exception
          (state-with-flash state (format "open failed: ~a" path*))
          'error 'io #f (list 'open path*) err)
         '())]
       [else
        (define engine (editor-engine ed))
        (define id (state-next-view-id state))
        (define mode (doc-mode-for path* text))
        (define name
          (let ([n (file-name-from-path path*)])
            (if n (path->string n) path*)))
        (void (engine-create-buffer! engine id name text))
        (void (engine-create-view! engine id id))
        (define version (engine-doc-version engine id))
        (define r (make-resource id id path* name (list id) mode version
                                 #:command-stack (mode-command-stack mode)))
        (define state*
          (state-with-next-view-id
           (state-with-resources
            state (resources-add (state-resources state) r))
           (add1 id)))
        (values (editor-placement-start state* id) '())])]))
