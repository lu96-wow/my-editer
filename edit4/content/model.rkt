#lang racket

;;; edit4/content/model.rkt —— 内容模型：文档 / 视图 / 面板 / 文件树
;;;
;;; World 只存本值（不透明）；文本真身在引擎里（值语义之外）。
;;;   ed       : 引擎（命令式盒）
;;;   docs     : did -> doc-meta（路径 / 存档时的 handle）
;;;   bindings : 窗口 id -> 它显示的 vid
;;;   panels   : 面板名 -> vid（面板是文档，不可编辑）
;;;   tree     : 文件树状态（#f = 未初始化）——从 edit3 的 features hash 收编而来
;;;
;;; 「脏」= 存档 handle ≠ 当前 handle（身份比较）。

(provide (struct-out content) (struct-out doc-meta)
         content-blank
         content-add-doc! content-add-view! content-add-panel! content-close-doc!
         content-bind content-unbind content-remove-vid
         content-vid-of content-did-of focused-vid-of
         content-doc-meta doc-path doc-dirty? doc-save-mark!
         content-panel-vid content-panel?
         content-tree content-set-tree)

(require racket/list "adapter.rkt")

(struct doc-meta (path saved) #:transparent)   ; saved = 存档时 handle | #f
(struct content (ed docs bindings panels tree) #:transparent)

(define (content-blank) (content (blank-editor) (hash) (hash) (hash) #f))

(define (content-ed* c ed) (struct-copy content c [ed ed]))
(define (content-docs* c docs) (struct-copy content c [docs docs]))
(define (content-bindings* c b) (struct-copy content c [bindings b]))
(define (content-panels* c p) (struct-copy content c [panels p]))
(define (content-set-tree c t) (struct-copy content c [tree t]))

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
  (define docs (hash-set (content-docs c) did (doc-meta #f (document-handle ed did))))
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
