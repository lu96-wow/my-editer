#lang racket

;;; edit4/content/lifecycle.rkt —— 文档资源的生命周期动词
;;;
;;;   dirty-dids   有未保存修改的文档
;;;   save-doc     持久化一个文档（写文件 effect + 标记 saved）
;;;   save-docs    批量
;;;   close-doc!   释放一个文档（解绑视图 + 删元数据 + 焦点回退）
;;;   ensure-focus 焦点窗不再显示文档时，回退到一个编辑器窗
;;;   doc-display  文档的显示名（有路径用文件名，否则用文档名）
;;;
;;; 这里只有动词（被命令 / prompt kind 复用），不含提示与键表。

(provide dirty-dids save-doc save-docs close-doc! ensure-focus doc-display
         window-of-vid show-view! show-doc! focused-did)

(require racket/list racket/path
         "../core/world.rkt" "../core/effect.rkt"
         "../layout/tree.rkt"
         "model.rkt" "adapter.rkt")

(define (dirty-dids c)
  (for/list ([did (in-list (document-id-list (content-ed c)))]
             #:when (doc-dirty? c did))
    did))

(define (doc-display w did)
  (define c (world-content w))
  (define m (and c (content-doc-meta c did)))
  (define p (and m (doc-path m)))
  (if p
      (path->string (file-name-from-path p))
      (document-name (content-ed c) did)))

;; save-doc : World did -> (values World (listof effect) Boolean)
;;   #f = 无文件名，没保存。
(define (save-doc w did)
  (define c (world-content w))
  (define m (and c did (content-doc-meta c did)))
  (define path (and m (doc-path m)))
  (cond
    [(not path) (values w '() #f)]
    [else (values (world-set-content w (doc-save-mark! c did))
                  (list (save-file path (document-string (content-ed c) did)))
                  #t)]))

(define (save-docs w dids)
  (for/fold ([w w] [effs '()]) ([did (in-list dids)])
    (define-values (w* e* _ok?) (save-doc w did))
    (values w* (append effs e*))))

;; 焦点窗不再显示任何文档（刚被关掉）→ 回退到一个编辑器窗 / 第一个窗。
(define (ensure-focus w)
  (define c (world-content w))
  (define f (world-focus w))
  (cond
    [(and f (has-id? w f) (content-vid-of c f)) w]
    [else
     (define target (or (content-editor-window c (world-layout w))
                        (for/first ([id (in-list (ids (world-layout w)))]) id)))
     (world-set-focus w target)]))

(define (close-doc! w did)
  (define c (world-content w))
  (cond
    [(not (and c did)) w]
    [else (ensure-focus (world-set-content w (content-close-doc! c did)))]))

;;; ---------- 显示 ----------

(define (window-of-vid w vid)
  (define c (world-content w))
  (and c vid
       (for/first ([id (in-list (ids (world-layout w)))]
                   #:when (eqv? (content-vid-of c id) vid))
         id)))

(define (focused-did w)
  (define c (world-content w))
  (define v (and c (content-vid-of c (world-focus w))))
  (and v (content-did-of c v)))

;; 显示一个视图：已显示的窗口→聚焦；否则放进一个编辑器窗。
(define (show-view! w vid)
  (define c (world-content w))
  (define id (window-of-vid w vid))
  (cond
    [id (world-set-focus w id)]
    [else
     (define t (or (content-editor-window c (world-layout w)) (world-focus w)))
     (if t
         (world-set-content (world-set-focus w t) (content-bind (world-content w) t vid))
         w)]))

;; 显示一个文档：复用其首个视图，否则新建一个视图再显示。
(define (show-doc! w did)
  (define c (world-content w))
  (define vids (document-view-list (content-ed c) did))
  (cond
    [(pair? vids) (show-view! w (car vids))]
    [else
     (define t (or (content-editor-window c (world-layout w)) (world-focus w)))
     (cond
       [(not t) w]
       [else (define-values (c* vid) (content-add-view! c did 60 22))
             (world-set-content (world-set-focus w t) (content-bind c* t vid))])]))
