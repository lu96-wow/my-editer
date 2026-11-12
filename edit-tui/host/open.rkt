#lang racket

;;; edit-tui/host/open.rkt —— 打开文件 / 去重 / placement
;;;
;;; 对齐旧行为：
;;;   已打开且 view 挂在 panel 上 -> 聚焦已有 panel
;;;   已打开但 detached          -> placement（不新建 doc）
;;;   未打开                     -> 读文件 / 新建 doc+view / 加 resource / placement
;;;
;;; IO 只在 host 解释 open-file-action 时发生。

(require racket/file
         racket/path
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../editor/engine/read.rkt"
         "../editor/engine/lifecycle.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt"
         "../editor/mode.rkt"
         "../editor/layout.rkt"
         "../features/placement/api.rkt"
         "keymap.rkt")

(provide editor-open-file!
         editor-focus-view!)

(define (focus-existing-resource state r)
  (define l (state-layout state))
  (define vid (and (pair? (resource-views r)) (car (resource-views r))))
  (define pid (and l vid (layout-panel-for-view l vid)))
  (cond
    [(not vid)
     (values (state-with-flash state "open: resource has no view") '())]
    [pid
     (define-values (l* ok?)
       (layout-panel-set-active-view l pid vid))
     (define l** (if ok? (layout-set-focus l* pid) (layout-set-focus l pid)))
     (values (state-with-layout state l**) '())]
    [else
     (values (editor-placement-start state vid) '())]))

;; 聚焦一个已经存在的 view：挂在 panel 上就切 active + 聚焦；detached 就 placement。
(define (editor-focus-view! ed state vid)
  (define l (state-layout state))
  (define pid (and l vid (layout-panel-for-view l vid)))
  (cond
    [(not vid) (values (state-with-flash state "focus-view: no view") '())]
    [pid
     (define-values (l* ok?) (layout-panel-set-active-view l pid vid))
     (define l** (if ok? (layout-set-focus l* pid) (layout-set-focus l pid)))
     (values (state-with-layout state l**) '())]
    [else (values (editor-placement-start state vid) '())]))

(define (editor-open-file! ed state path)
  (define path* (resource-normalize-path path))
  (define existing (resources-find-path (state-resources state) path*))
  (cond
    [existing (focus-existing-resource state existing)]
    [else
     (define text
       (with-handlers ([exn:fail? (λ (_) #f)])
         (file->string path*)))
     (cond
       [(not text)
        (values (state-with-flash state (format "open failed: ~a" path*)) '())]
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
