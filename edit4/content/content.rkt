#lang racket

;;; edit4/content/content.rkt —— 文档 / 视图的内容层
;;;
;;; World 只存「引擎 handle + 元数据」；文本真身在引擎里（值语义之外，见 DESIGN）。
;;;   ed       : 引擎（命令式盒）
;;;   docs     : did -> doc-meta（路径 / 存档时的 handle）
;;;   bindings : 窗口 id -> 它显示的 vid（布局 id 是不透明的，绑定在这里）
;;;
;;; 「脏」= 存档 handle ≠ 当前 handle（身份比较，不比较文本）。

(provide (struct-out content) (struct-out doc-meta)
         content-blank
         content-add-doc! content-add-view! content-close-doc!
         content-bind content-unbind content-remove-vid
         content-vid-of content-did-of focused-vid-of
         content-doc-meta doc-path doc-dirty? doc-save-mark!
         content-docs-set)

(require racket/list "engine.rkt")

(struct doc-meta (path saved) #:transparent)   ; saved = 存档时的 document handle | #f
(struct content (ed docs bindings) #:transparent)

(define (content-blank) (content (blank-editor) (hash) (hash)))

(define (content-docs-set c docs) (content (content-ed c) docs (content-bindings c)))

;;; ---------- 增删 ----------

;; → (values content did vid)
(define (content-add-doc! c text w h name path)
  (define-values (ed did vid) (add-document-view! (content-ed c) text w h name))
  (define docs (hash-set (content-docs c) did (doc-meta path (document-handle ed did))))
  (values (content ed docs (content-bindings c)) did vid))

;; 给已有文档再加一个视图 → (values content vid)
(define (content-add-view! c did w h)
  (define-values (ed vid) (add-view! (content-ed c) did w h))
  (values (content ed (content-docs c) (content-bindings c)) vid))

(define (content-close-doc! c did)
  (define ed (close-document (content-ed c) did))
  ;; 该文档的视图 → 解除绑定（对应窗口变空）
  (define gone
    (for/hash ([v (in-list (document-view-list (content-ed c) did))]) (values v #t)))
  (define binds
    (for/hash ([(id vid) (in-hash (content-bindings c))] #:unless (hash-has-key? gone vid))
      (values id vid)))
  (content ed (hash-remove (content-docs c) did) binds))

;;; ---------- 绑定（窗口 id ↔ 视图） ----------

(define (content-bind c id vid) (content (content-ed c) (content-docs c) (hash-set (content-bindings c) id vid)))
(define (content-unbind c id) (content (content-ed c) (content-docs c) (hash-remove (content-bindings c) id)))
(define (content-vid-of c id) (hash-ref (content-bindings c) id #f))
(define (content-did-of c vid) (and vid (view-did (content-ed c) vid)))
(define (focused-vid-of c id) (content-vid-of c id))

;; 某 vid 不再被任何窗口显示时，可关闭它（清资源）。当前先只解绑由调用方处理。
(define (content-remove-vid c vid)
  (content (close-view (content-ed c) vid) (content-docs c)
           (for/hash ([(id v) (in-hash (content-bindings c))] #:unless (eqv? v vid)) (values id v))))

;;; ---------- 元数据 / 脏 ----------

(define (content-doc-meta c did) (hash-ref (content-docs c) did #f))
(define (doc-path m) (and m (doc-meta-path m)))
(define (doc-dirty? c did)
  (define m (hash-ref (content-docs c) did #f))
  (and m (let ([s (doc-meta-saved m)])
           (and s (not (eq? s (document-handle (content-ed c) did)))))))

;; 保存后标记干净：saved = 当前 handle。
(define (doc-save-mark! c did)
  (define m (hash-ref (content-docs c) did #f))
  (if m
      (content (content-ed c)
               (hash-set (content-docs c) did (struct-copy doc-meta m [saved (document-handle (content-ed c) did)]))
               (content-bindings c))
      c))
