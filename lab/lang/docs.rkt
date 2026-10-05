#lang racket

;;; lab-rebuild/lang/docs.rkt —— 标识符 → 文档（签名 + 说明 + 链接）
;;;
;;; 数据来源与 racket-langserver 同一条管线：
;;;   setup/xref        按 (模块 符号) 反查定义 tag（会跟到 re-export 的原始定义）
;;;   scribble/blueboxes 取签名（函数 / 语法骨架）
;;;   racket-langserver/doclib/documentation-parser 从本地 HTML 文档抽正文
;;;
;;; 本文件只认「标识符 + 候选模块」，不认识 app / editor。候选模块由 lang/source 给出。
;;; 结果全量缓存（tag → doc），xref 懒加载，避免拖慢启动。

(provide (struct-out doc) docs-for doc->text)

(require racket/list racket/string net/url
         (only-in setup/xref load-collections-xref)
         (only-in scribble/xref xref-binding->definition-tag xref-tag->path+anchor)
         (only-in scribble/blueboxes make-blueboxes-cache fetch-blueboxes-strs)
         (only-in racket-langserver/doclib/documentation-parser
                  extract-documentation-for-selected-element)
         (only-in racket-langserver/doclib/docs-helpers
                  make-proper-url-for-online-documentation))

;; name        : string          查的名字
;; module      : 候选模块路径（查到定义的那个）
;; signature   : string / #f     bluebox 签名
;; description : string / #f     HTML 正文
;; url         : string / #f     在线文档链接
(struct doc (name module signature description url) #:transparent)

;;; ================= 缓存 =================

(define xref (delay (load-collections-xref)))
(define bluebox-cache (make-blueboxes-cache #t))
(define doc-cache (make-hash))          ; tag -> doc

;;; ================= 查（按模块列表） =================

;; 在候选模块里找一个导出该名字的模块，返回它的定义 tag（#f = 找不到）。
(define (tag-for id mods)
  (for/or ([m (in-list mods)])
    (with-handlers ([exn:fail? (λ (_) #f)])
      (xref-binding->definition-tag (force xref) (list m id) #f))))

;; id : string。mods : (listof module-path)。返回 doc 或 #f。
(define (docs-for id #:modules [mods '()])
  (define id* (string->symbol id))
  (define tag (tag-for id* mods))
  (and tag (tag->doc id id* tag)))

(define (tag->doc id id* tag)
  (hash-ref! doc-cache tag
    (λ ()
      (define-values (path anchor) (xref-tag->path+anchor (force xref) tag))
      (define signature (tag->signature tag))
      (define description (and path (tag->description path anchor)))
      (define url (and path (file-url->online (path->url+anchor path anchor))))
      (doc id #f signature description url))))

;; bluebox 首元素是类别（procedure / syntax / …），其余是签名骨架（已对齐）。
(define (tag->signature tag)
  (define bbs
    (with-handlers ([exn:fail? (λ (_) #f)])
      (fetch-blueboxes-strs tag #:blueboxes-cache bluebox-cache)))
  (and (pair? bbs)
       (string-join (cdr bbs) "\n")))

;; 读本地 HTML，抽出该 tag 的正文。
(define (tag->description path anchor)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (extract-documentation-for-selected-element
     (url->string (path->url+anchor path anchor))
     #:include-signature? #f)))

(define (path->url+anchor path anchor)
  (struct-copy url (path->url path) [fragment anchor]))

;; file:///…/doc/reference/pairs.html#… → https://docs.racket-lang.org/reference/pairs.html#…
(define (file-url->online file-url)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (make-proper-url-for-online-documentation (url->string file-url))))

;;; ================= 展示 =================

;; 把 doc 排成一段可放进只读文档的文本。
(define (doc->text d)
  (define body (or (doc-description d) ""))
  (string-append
   (doc-name d) "\n"
   (if (doc-url d) (string-append (doc-url d) "\n") "")
   "\n"
   (if (doc-signature d) (string-append (doc-signature d) "\n\n") "")
   body
   (if (string-suffix? body "\n") "" "\n")))
