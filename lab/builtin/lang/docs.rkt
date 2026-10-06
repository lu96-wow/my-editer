#lang racket

;;; lab-rebuild/lang/docs.rkt —— 标识符 → 文档（DrRacket 式：只取 bluebox）
;;;
;;; 与 DrRacket 的 check-syntax 蓝框同一套数据：
;;;   setup/xref         按 (模块 符号) 反查定义 tag（会跟到 re-export 的原始定义）
;;;   scribble/blueboxes 取 bluebox 字符串（类别 + 签名 / 契约，已排版对齐）
;;;
;;; DrRacket 的浮层就是把这些字符串原样画出来（并给个 “read more” 链接），**不解析**
;;; 文档 HTML 正文。这里照做：只展示 bluebox，不去抓 HTML、不做 markdown 剥离，
;;; 因此查文档不用碰网络 / 大依赖，首次也就几毫秒。
;;;
;;; 本文件只认「标识符 + 候选模块」，不认识 app / editor；候选模块由 lang/source 给出。
;;; 结果全量缓存（tag → doc），xref 懒加载。

(provide (struct-out doc) docs-for doc->text doc->result result->doc)

(require racket/list racket/string
         (only-in setup/xref load-collections-xref)
         (only-in scribble/xref xref-binding->definition-tag)
         (only-in scribble/blueboxes make-blueboxes-cache fetch-blueboxes-strs))

;; name      : string        查的名字
;; signature : string / #f   bluebox 全部字符串（类别 + 签名 / 契约），已对齐
(struct doc (name signature) #:transparent)

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
  (and tag (tag->doc id tag)))

(define (tag->doc id tag)
  (hash-ref! doc-cache tag (λ () (doc id (tag->bluebox tag)))))

;; bluebox 全部字符串（DrRacket 也是整个列表都显示）；取不到 → #f。
(define (tag->bluebox tag)
  (define bbs
    (with-handlers ([exn:fail? (λ (_) #f)])
      (fetch-blueboxes-strs tag #:blueboxes-cache bluebox-cache)))
  (and (pair? bbs) (string-join bbs "\n")))

;;; ================= 展示 =================

;; 浮窗内容：bluebox；没有 bluebox 就退回名字。
(define (doc->text d)
  (string-append (or (doc-signature d) (doc-name d)) "\n"))

;;; ================= 跨 place 编解码（结果只用普通 list，避免 struct 身份问题） =================

(define (doc->result d) (and d (list (doc-name d) (doc-signature d))))
(define (result->doc r) (and r (apply doc r)))
