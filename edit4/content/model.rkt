#lang racket

;;; edit4/content/model.rkt —— 内容模型：文档 / 视图 / 面板 / 文件树
;;;
;;; World 只存本值（不透明）；文本真身在引擎里（值语义之外）。
;;;   ed       : 引擎（命令式盒）
;;;   docs     : did -> doc-meta（路径 / 存档时的 handle）
;;;   bindings : 窗口 id -> 它显示的 vid
;;;   panels   : 面板名 -> vid（面板是文档，不可编辑）
;;;   tree     : 文件树状态（#f = 未初始化）——从 edit3 的 features hash 收编而来
;;;   prompt   : 输入行状态 | #f
;;;   regions  : 面板槽（窗口显示多个面板之一，互斥）：rid -> region
;;;   fold     : 文档管理面板的折叠集：did -> #t
;;;   log      : 日志行（append-only）：(listof string)
;;;
;;; 「脏」= 存档 handle ≠ 当前 handle（身份比较）。

(provide (struct-out content) (struct-out doc-meta) (struct-out prompt) (struct-out placing) (struct-out region)
         content-blank
         content-add-doc! content-add-view! content-add-panel! content-close-doc!
         content-bind content-unbind content-remove-vid
         content-vid-of content-did-of focused-vid-of content-wid-of-vid
         content-doc-meta doc-path doc-dirty? doc-save-mark!
         content-panel-vid content-panel? panel-doc-name? panel-name-of-vid
         content-prompt content-set-prompt
         content-placing content-set-placing
         content-tree content-set-tree
         content-regions content-set-regions
         content-fold content-set-fold
         content-log content-log-append
         content-doc-key content-set-doc-key
         path-key content-doc-by-path content-doc-paths content-show content-editor-window
         content-editor-windows content-empty-windows)

(require racket/list racket/path "../layout/tree.rkt" "adapter.rkt")

(struct doc-meta (path saved) #:transparent)   ; saved = 存档时 handle | #f（面板恒为 #f）
(struct prompt (wid label kind data prev-focus) #:transparent)  ; 输入行状态
;; 放置选择（打开时多窗口 → 用户选目标窗）；vid = 待放置视图，prev-focus = 进入前焦点。
(struct placing (vid prev-focus) #:transparent)
;; 面板槽：一个窗口显示 members 之一（面板文档名），active = 当前成员；
;; wid = 当前显示的窗口 id | #f（隐藏）；anchor = 'root | 'main；size 固定。
(struct region (side size members active anchor wid) #:transparent)
(struct content (ed docs bindings panels tree prompt placing regions fold log doc-keys) #:transparent)

(define (content-blank) (content (blank-editor) (hash) (hash) (hash) #f #f #f (hash) (hash) '() (hash)))

(define (content-ed* c ed) (struct-copy content c [ed ed]))
(define (content-docs* c docs) (struct-copy content c [docs docs]))
(define (content-bindings* c b) (struct-copy content c [bindings b]))
(define (content-panels* c p) (struct-copy content c [panels p]))
(define (content-set-tree c t) (struct-copy content c [tree t]))
(define (content-set-prompt c p) (struct-copy content c [prompt p]))
(define (content-set-placing c p) (struct-copy content c [placing p]))
(define (content-set-regions c r) (struct-copy content c [regions r]))
(define (content-set-fold c f) (struct-copy content c [fold f]))
(define (content-log-append c msg) (struct-copy content c [log (append (content-log c) (list msg))]))

;; 文档键表：打开文档时按 matcher 挂到 did（mode 层产出）。
;; content-doc-keys 是 struct 自动访问器（did -> 键表 的 hash）。
(define (content-doc-key c did) (hash-ref (content-doc-keys c) did #f))
(define (content-set-doc-key c did table)
  (struct-copy content c [doc-keys (hash-set (content-doc-keys c) did table)]))

;;; ---------- 增 ----------

(define (content-add-doc! c text w h name path)
  (define-values (ed did vid) (add-document-view! (content-ed c) text w h name))
  (define docs (hash-set (content-docs c) did (doc-meta path (document-handle ed did))))
  (values (content-docs* (content-ed* c ed) docs) did vid))

(define (content-add-view! c did w h)
  (define-values (ed vid) (add-view! (content-ed c) did w h))
  (values (content-ed* c ed) vid))

(define (content-add-panel! c name w h)
  (define-values (ed did vid) (add-panel! (content-ed c) "" w h name))
  ;; 面板不可保存：saved = #f → 永远不脏。
  (define docs (hash-set (content-docs c) did (doc-meta #f #f)))
  (define panels (hash-set (content-panels c) name vid))
  (values (content-panels* (content-docs* (content-ed* c ed) docs) panels) did vid))

(define (content-close-doc! c did)
  (define ed (close-document (content-ed c) did))
  (define gone (for/hash ([v (in-list (document-view-list (content-ed c) did))]) (values v #t)))
  (define binds
    (for/hash ([(id vid) (in-hash (content-bindings c))] #:unless (hash-has-key? gone vid))
      (values id vid)))
  (content-bindings* (content-docs* (content-ed* c ed) (hash-remove (content-docs c) did)) binds))

;;; ---------- 绑定 ----------

(define (content-bind c id vid) (content-bindings* c (hash-set (content-bindings c) id vid)))
(define (content-unbind c id) (content-bindings* c (hash-remove (content-bindings c) id)))
(define (content-vid-of c id) (hash-ref (content-bindings c) id #f))
(define (content-wid-of-vid c vid)
  (and vid (for/first ([(id v) (in-hash (content-bindings c))] #:when (eqv? v vid)) id)))
(define (content-did-of c vid) (and vid (view-did (content-ed c) vid)))
(define (focused-vid-of c id) (content-vid-of c id))

(define (content-remove-vid c vid)
  (content-panels*
   (content-bindings*
    (content-ed* c (close-view (content-ed c) vid))
    (for/hash ([(id v) (in-hash (content-bindings c))] #:unless (eqv? v vid)) (values id v)))
   (for/hash ([(nm v) (in-hash (content-panels c))] #:unless (eqv? v vid)) (values nm v))))

;;; ---------- 面板 ----------

(define (content-panel-vid c name) (hash-ref (content-panels c) name #f))
(define (content-panel? c vid)
  (and vid (for/or ([(nm v) (in-hash (content-panels c))]) (eqv? v vid)) #t))
(define (panel-doc-name? c name) (and name (hash-has-key? (content-panels c) name) #t))
(define (panel-name-of-vid c vid)
  (and vid (for/first ([(nm v) (in-hash (content-panels c))] #:when (eqv? v vid)) nm)))

;;; ---------- 元数据 / 脏 ----------

(define (content-doc-meta c did) (hash-ref (content-docs c) did #f))
(define (doc-path m) (and m (doc-meta-path m)))
(define (doc-dirty? c did)
  (define m (hash-ref (content-docs c) did #f))
  (and m (let ([s (doc-meta-saved m)])
           (and s (not (eq? s (document-handle (content-ed c) did)))))))

(define (doc-save-mark! c did)
  (define m (hash-ref (content-docs c) did #f))
  (if m
      (content-docs* c
                     (hash-set (content-docs c) did
                               (struct-copy doc-meta m [saved (document-handle (content-ed c) did)])))
      c))

;;; ---------- 资源：路径 → 文档 / 显示 ----------

;; 路径规范化（比较用）：绝对 + 简化 + explode（消除结尾分隔符差异）。
(define (path-key p) (explode-path (simplify-path (path->complete-path p))))

;; 已打开且路径为 p 的文档；没有 → #f。
(define (content-doc-by-path c p)
  (define k (path-key p))
  (for/first ([did (in-list (document-id-list (content-ed c)))]
              #:when (let ([m (hash-ref (content-docs c) did #f)])
                       (and m (doc-path m) (equal? k (path-key (doc-path m))))))
    did))

;; 所有已打开文档的路径（文件树着色用）。
(define (content-doc-paths c)
  (for/list ([did (in-list (document-id-list (content-ed c)))]
             #:when (let ([m (hash-ref (content-docs c) did #f)]) (and m (doc-path m))))
    (doc-path (hash-ref (content-docs c) did))))

;; 在窗口 id 显示文档 did：复用其已有视图，否则新建一个视图。
(define (content-show c id did)
  (define vids (document-view-list (content-ed c) did))
  (cond
    [(pair? vids) (content-bind c id (car vids))]
    [else (define-values (c* vid) (content-add-view! c did 60 22))
          (content-bind c* id vid)]))

;; 选一个「编辑器窗口」（vid 非面板或空）来显示文档；没有 → #f。
(define (content-editor-windows c layout)
  (for/list ([id (in-list (ids layout))]
             #:when (let ([v (content-vid-of c id)])
                      (or (not v) (not (content-panel? c v)))))
    id))

(define (content-editor-window c layout)
  (for/first ([id (in-list (ids layout))]
              #:when (let ([v (content-vid-of c id)])
                       (or (not v) (not (content-panel? c v)))))
    id))

;; 空窗口 = 未绑定任何 vid 的窗口。
(define (content-empty-windows c layout)
  (for/list ([id (in-list (ids layout))] #:when (not (content-vid-of c id))) id))
