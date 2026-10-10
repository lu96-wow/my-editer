#lang racket

;;; edit-rebuild/plugins/lang/docs.rkt —— 标识符 → 文档（DrRacket 式：bluebox 优先，HTML 兜底）
;;;
;;; 与 DrRacket 的 check-syntax 蓝框同一套数据：
;;;   setup/xref         按 (模块 符号) 反查定义 tag（会跟到 re-export 的原始定义）
;;;   scribble/blueboxes 取 bluebox 字符串（类别 + 签名 / 契约，已排版对齐）
;;;
;;; bluebox 拿不到时（如 linked 包的文档不在搜索目录），再用 xref 给出的 HTML 路径
;;; 抽正文（lang/doc-html）。DrRacket 浮层本身只画 bluebox，但为了对齐
;;; racket-langserver 的 hover，这里多一层 HTML 正文兜底。
;;;
;;; 本文件只认「标识符 + 候选模块」，不认识 app / editor；候选模块由 lang/source 给出。
;;; 结果全量缓存（tag → doc），xref 懒加载。

(provide (struct-out doc) docs-for doc->text doc->result result->doc)

(require racket/list racket/string racket/path
         (only-in setup/xref load-collections-xref)
         (only-in scribble/xref xref-binding->definition-tag xref-tag->path+anchor)
         (only-in scribble/blueboxes make-blueboxes-cache fetch-blueboxes-strs)
         "doc-html.rkt")

;; name      : string        查的名字
;; signature : string / #f   bluebox 全部字符串（类别 + 签名 / 契约），已对齐
;; body      : string / #f   HTML 文档页抽出的正文（markdown）；bluebox 缺失时含签名
(struct doc (name signature body) #:transparent)

;;; ================= 缓存 =================

(define xref (delay (load-collections-xref)))
(define bluebox-cache (make-blueboxes-cache #t))
(define doc-cache (make-hash))          ; tag -> doc

;; linked 包（`raco pkg install --link`）的 blueboxes.rktd 渲染在包目录里，
;; 不在 `(get-doc-search-dirs)`（安装级 + 用户级 doc）里，默认缓存因而查不到；
;; 但 xref 仍能由 tag 给出 HTML 路径。按目录惰性另建缓存，补上这批包。
(define bluebox-dir-caches (make-hash)) ; dir -> blueboxes-cache

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
  (and tag (tag->doc id tag)))

(define (tag->doc id tag)
  (hash-ref! doc-cache tag
             (λ ()
               (define sig (tag->bluebox tag))
               (doc id sig (tag->html-body tag (not sig))))))

(define (fetch-strs tag cache)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (fetch-blueboxes-strs tag #:blueboxes-cache cache)))

;; tag 的 HTML 所在目录（同目录通常就有 blueboxes.rktd）。
(define (tag-dir tag)
  (define path
    (with-handlers ([exn:fail? (λ (_) #f)])
      (define-values (p _a) (xref-tag->path+anchor (force xref) tag))
      p))
  (and (path? path)
       (let-values ([(d _f _m) (split-path path)]) d)))

;; bluebox 全部字符串（DrRacket 也是整个列表都显示）；取不到 → #f。
(define (tag->bluebox tag)
  (define bbs
    (or (fetch-strs tag bluebox-cache)
        (let* ([dir (tag-dir tag)]
               [cache (and dir
                           (file-exists? (build-path dir "blueboxes.rktd"))
                           (hash-ref! bluebox-dir-caches dir
                                      (λ () (make-blueboxes-cache #t #:blueboxes-dirs (list dir)))))])
          (and cache (fetch-strs tag cache)))))
  (and (pair? bbs) (string-join bbs "\n")))

;; bluebox 缺失时，由 HTML 文档页抽正文。有 bluebox 就不重复带签名（#:include-signature? #f）。
(define (tag->html-body tag include-signature?)
  (define uri (docs-uri-for-tag tag))
  (define body
    (and uri
         (with-handlers ([exn:fail? (λ (_) #f)])
           (extract-documentation-for-selected-element uri #:include-signature? include-signature?))))
  (and (string? body) (non-empty-string? body) body))

;;; ================= 展示 =================

;; 浮窗内容：bluebox 签名优先；正文（HTML）接在后面。
;; 无签名时正文自带签名（include-signature? #t），不再重复打印名字。
(define (doc->text d)
  (define sig (doc-signature d))
  (define body (doc-body d))
  (string-append
   (cond [sig sig]
         [body ""]
         [else (doc-name d)])
   (if body (string-append (if sig "\n\n" "") body) "")
   "\n"))

;;; ================= 跨 place 编解码（结果只用普通 list，避免 struct 身份问题） =================

(define (doc->result d) (and d (list (doc-name d) (doc-signature d) (doc-body d))))
(define (result->doc r) (and r (apply doc r)))
