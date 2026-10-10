#lang racket

;;; edit/lang/doc-html.rkt —— 由 tag 的 HTML 文档页抽取正文（GFM markdown）。
;;;
;;; 移植自 racket-langserver 的 doclib/documentation-parser.rkt（MIT）。
;;; 用途：bluebox 取不到时的兜底 —— xref tag → (path . anchor) → file URL →
;;; 解析 HTML → 找锚点所在的 SIntrapara（签名块）→ 顺序收集到下一个边界 →
;;; 转 markdown。只认 tag，不认识 app / editor。
;;;
;;; 与 racket-langserver 的差异：
;;;   · `extract-documentation-for-selected-element` 的缓存键含 include-signature?，
;;;     避免先取「带签名」再取「不带签名」时命中同一份。
;;;   · 另外提供 `docs-uri-for-tag`（tag → 本地 file URL）。

(provide extract-documentation-for-selected-element
         docs-uri-for-tag)

(require racket/match
         racket/string
         racket/format
         racket/function
         net/url
         net/url-string
         html-parsing
         (only-in setup/xref load-collections-xref)
         (only-in scribble/xref xref-tag->path+anchor))

;;; ================= tag → 本地文档 URL =================

(define xref (delay (load-collections-xref)))

;; 例："file:///.../doc/index/index.html#(def._((lib._tui/main..rkt)._with-tui))"；无则 #f。
(define (docs-uri-for-tag tag)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (define-values (path anchor) (xref-tag->path+anchor (force xref) tag))
    (and (path? path)
         (url->string (struct-copy url (path->url path) [fragment anchor])))))

;;; ================= Cursor（Zipper，HTML 节点导航） =================
;; 思路来自 wescheme-docs/tree-cursor.rkt。

(struct cursor (selected-node lefts parent rights) #:transparent)
(define (make-cursor tree-node) (cursor tree-node '() #f '()))

(define (cursor-can-go-down? current-cursor)
  (match current-cursor [(cursor (list fst-child _ ...) _ _ _) #t] [_ #f]))
(define (cursor-can-go-up? current-cursor)
  (match current-cursor [(cursor _ _ parent _) #:when parent #t] [_ #f]))
(define (cursor-can-go-left? current-cursor)
  (match current-cursor [(cursor _ (list left-sibling _ ...) _ _) #t] [_ #f]))
(define (cursor-can-go-right? current-cursor)
  (match current-cursor [(cursor _ _ _ (list right-sibling _ ...)) #t] [_ #f]))

(define (cursor-go-down current-cursor)
  (match current-cursor
    [(cursor (list fst-child others ...) _ _ _)
     (cursor fst-child '() current-cursor others)]
    [_ (error "Cursor can't move down!")]))
(define (cursor-go-up current-cursor)
  (match current-cursor
    [(cursor selected-node lefts parent rights)
     (cursor (append (reverse lefts) (cons selected-node rights))
             (cursor-lefts parent) (cursor-parent parent) (cursor-rights parent))]
    [_ (error "Cursor can't move up!")]))
(define (cursor-go-up-until-true cursor predicate?)
  (cond
    [(predicate? (cursor-selected-node cursor)) cursor]
    [(cursor-can-go-up? cursor) (cursor-go-up-until-true (cursor-go-up cursor) predicate?)]
    [else #f]))
(define (cursor-go-left current-cursor)
  (match current-cursor
    [(cursor selected-node (list fst-left-sibling others ...) parent rights)
     (cursor fst-left-sibling others parent (cons selected-node rights))]
    [_ (error "Cursor can't move left!")]))
(define (cursor-go-right current-cursor)
  (match current-cursor
    [(cursor selected-node lefts parent (list fst-right-sibling others ...))
     (cursor fst-right-sibling (cons selected-node lefts) parent others)]
    [_ (error "Cursor can't move right!")]))
(define (cursor-go-to-next-sibling-or-uncle-node cursor doc-is-nested?)
  (define (is-outside-of-blockquote? cursor) (is-blockquote-leftindent? (cursor-selected-node cursor)))
  (cond
    [(cursor-can-go-right? cursor) (cursor-go-right cursor)]
    [(cursor-can-go-up? cursor)
     (define parent-cursor (cursor-go-up cursor))
     (cond
       ;; 当前解析的是 `nested` 文档时，不要越出它的范围 —— 到此为止。
       [(and doc-is-nested? (is-outside-of-blockquote? parent-cursor)) #f]
       [else (cursor-go-to-next-sibling-or-uncle-node parent-cursor doc-is-nested?)])]
    [else #f]))

;;; ================= 找「选中元素」的文档边界 =================

(define (find-doc-beginning-and-take-cursor doc-xexp anchor-name)
  (define (find-node predicate? cursor)
    (cond
      [(predicate? (cursor-selected-node cursor)) cursor]
      [(cursor-can-go-down? cursor) (find-node predicate? (cursor-go-down cursor))]
      [(cursor-can-go-right? cursor) (find-node predicate? (cursor-go-right cursor))]
      [(cursor-can-go-up? cursor)
       (let loop ([cursor cursor])
         (cond
           [(cursor-can-go-right? cursor) (find-node predicate? (cursor-go-right cursor))]
           [(cursor-can-go-up? cursor) (loop (cursor-go-up cursor))]
           [else #f]))]
      [else #f]))
  (define (find-doc-beginning cursor)
    (or
      (cursor-go-up-until-true cursor
                               (match-lambda [`(div (@ (class "SIntrapara")) ,_ ...) #t] [_ #f]))
      ;; 万一没写 <div class="SIntrapara">
      (cursor-go-up-until-true cursor
                               (match-lambda [`(blockquote (@ (class "SVInsetFlow")) ,_ ...) #t] [_ #f]))))
  (define maybe-cursor (find-node
                         (λ (x) (equal? x (list 'name anchor-name)))
                         (make-cursor doc-xexp)))
  (and maybe-cursor (find-doc-beginning maybe-cursor)))

(define (selected-node-contains-documentation-boundary? cursor doc-is-nested?)
  (define (find-boundary-node predicate? tree)
    (cond
      ;; 若选中文档本身不是 nested，则收集嵌套文档时不检查它们的边界。
      [(and (not doc-is-nested?) (is-blockquote-leftindent? tree)) #f]
      ;; 列表整体收下，不管内部边界。
      [(tag-name? tree 'ul) #f]
      [(predicate? tree) tree]
      [(list? tree) (ormap (λ (x) (find-boundary-node predicate? x)) tree)]
      [else #f]))
  (find-boundary-node
    (match-lambda
      ;; 下一个函数 / 方法 / struct 等的文档开头
      [`(div (@ (class "RBackgroundLabelInner"))
             (p ,(or "class" "constructor" "interface" "method" "mixin" "parameter" "procedure" "signature" "struct" "syntax" "value"))) #t]
      ;; 文档列表结尾，如 <div class="navsetbottom">
      [`(@ (class "navsetbottom")) #t]
      ;; 模块结尾，如 <h5 x-source-module="..." ...>
      [`(@ (x-source-module ,_) ,_ ...) #t]
      [_ #f])
    (cursor-selected-node cursor)))

(define (collect-docs cursor doc-is-nested? [is-inside-boundary-node? #f])
  (cond [(not cursor) '()]
        ;; 顺序收集，直到遇到「属于另一个元素」的文档边界。
        [(selected-node-contains-documentation-boundary? cursor doc-is-nested?)
         ;; 边界节点可能是仍含本文档元素的 <p>，先只往里探一次。
         (define node (cursor-selected-node cursor))
         (if (and (not is-inside-boundary-node?) (list? node) (> (length node) 1))
             (list (car node) ; tag name
                   (collect-docs (cursor-go-right (cursor-go-down cursor)) doc-is-nested? #t))
             '())]
        [else
         (define next-node-cursor (cursor-go-to-next-sibling-or-uncle-node cursor doc-is-nested?))
         (cons (cursor-selected-node cursor)
               (collect-docs next-node-cursor doc-is-nested? is-inside-boundary-node?))]))

;;; ================= HTML → Markdown (GFM) =================

(define (tag? mb-tag)
  (match mb-tag [(list tag-name _ ...) #:when (not (eq? '@ tag-name)) #t] [_ #f])) ; 忽略属性 "('@ ...)"
(define (tag-name? tag name)
  (match tag [(list (== name) _ ...) #t] [_ #f]))
(define (get-tag-attribute tag attr-name)
  (match tag
    [(list _ ... (list '@ _ ... (list (== attr-name) attr-value) _ ...) _ ...) attr-value] [_ #f]))
(define (tag-attribute? tag attr-name attr-value)
  (equal? attr-value (get-tag-attribute tag attr-name)))
(define (is-blockquote-leftindent? tree-node)
  (match tree-node [`(blockquote (@ (class "leftindent") ,_ ...) ,_ ...) #t] [_ #f]))

;; 尽力把 html-parsing 产出的 SXML/xexp 转成 Markdown 字符串。
(define (html->markdown html-tag html-file-path)
  (define code-block-depth 0)
  (define list-element-depth 0)
  (define reference-links-table (make-hash))

  (define (recursive-convert tag [parent #f])
    (define inside-code-block? (> code-block-depth 0))
    (define inside-list-element? (> list-element-depth 0))

    (define (convert-tag-contents) (string-join (map (λ (child-tag) (recursive-convert child-tag tag)) tag) ""))
    (define (should-be-in-fenced-code-block? tag) (or (tag-attribute? tag 'class "SCodeFlow") (and (tag-name? tag 'table) (not inside-code-block?))))
    (define (should-be-emphasized? tag) (ormap (λ (x) (tag-attribute? tag 'class x)) '("RktVar" "RktVal")))
    (define (ignore? tag) (ormap (λ (x) (tag-attribute? tag 'class x)) '("refcolumn" "RBackgroundLabelInner")))
    (define (escape-markdown str)
      (if inside-code-block? str ; markdown 代码块内默认全部转义
          (regexp-replace*
            #rx"[\n<>]" str
            (match-lambda
              ;; 否则像 "#<void>" 会被 Md 当成 html 标签吃掉。
              ["<" "❮"] [">" "❯"]
              ["\n" " "] [s s]))))

    ;; markdown 只在代码块外支持 html 实体。
    (define (convert-if-tag-is-html-entity tag)
      (match tag ['(& nbsp) " "] ['(& rarr) "->"] ['(& rsquo) "'"] ['(& ldquo) "\""] ['(& rdquo) "\""] ['(& ndash) "-"] [_ #f]))

    (cond
      [(string? tag) (escape-markdown tag)]
      [(convert-if-tag-is-html-entity tag) => identity]
      [(or (not (tag? tag)) (ignore? tag)) ""] ; 垃圾或纯装饰标签
      [(tag-name? tag 'br) "  \n"] ; 两个空格 + 换行，允许在强调 *...* 内断行
      ;;
      [(tag-attribute? tag 'class "SHistory") (~a "\n\n*" (convert-tag-contents) "*")] ; changelog
      [(tag-name? tag 'tr) (~a "\n" (convert-tag-contents))]
      [(and (tag-name? tag 'p) (not inside-code-block?)) (~a (if inside-list-element? " " "\n\n") (convert-tag-contents))]
      [(and (tag-name? tag 'ul)) (~a (convert-tag-contents) "\n\n")]
      [(and (should-be-emphasized? tag) (not inside-code-block?)) (~a "*" (string-trim (convert-tag-contents)) "*")]

      ;; <blockquote class="leftindent"> 通常是嵌套文档；缩进成列表项展示。
      [(or (tag-name? tag 'li)
           (and (is-blockquote-leftindent? tag) (not inside-code-block?)
                (match parent [`(,_ (@ ,_) (blockquote ,_ ...)) #f] [_ #t]))) ; 单层 blockquote 不再缩进
       (set! list-element-depth (add1 list-element-depth))
       (define contents (string-trim (convert-tag-contents)))
       (set! list-element-depth (sub1 list-element-depth))
       (if (non-empty-string? contents)
           (~a "\n-   "
               (string-replace contents "\n" "\n    ") ; 每行缩进
               (if (tag-name? tag 'li) "" "\n"))
           "")]

      [(should-be-in-fenced-code-block? tag) ; 主要是代码块，也含 <table>
       (set! code-block-depth (add1 code-block-depth))
       (define codeblock-contents (string-trim (string-replace (convert-tag-contents) "\n\n" "\n")))
       (set! code-block-depth (sub1 code-block-depth))
       (~a "\n\n```\n" codeblock-contents "\n```\n\n")]

      [(or (and (tag-name? tag 'a) (not inside-code-block?)) (tag-name? tag 'img)) ; 链接 / 图片
       ;; 相对 URL 换成绝对在线文档 URL（离线链接在终端里也没法点，但保持可读）。
       (define is-img? (tag-name? tag 'img))
       (define mb-link-attr (get-tag-attribute tag (if is-img? 'src 'href)))
       (define maybe-url (if mb-link-attr
                             (make-proper-url-for-online-documentation mb-link-attr html-file-path) #f))
       (cond
         [(not maybe-url) (convert-tag-contents)] ; 空 href → 无链接
         [is-img?
          (define img (~a "![" (or (get-tag-attribute tag 'alt) "HereWasImage") "](" maybe-url ")"))
          (if inside-code-block? (~a "\n```\n" img "\n```\n") img)]
         [else
          (define contents (convert-tag-contents))
          (hash-set! reference-links-table contents maybe-url)
          (~a "[" contents "]")])]

      [else (convert-tag-contents)]))

  ;; 收尾：合并连续强调区 / 多余空行，提高无 markdown 渲染时的可读性。
  (define generated-markdown (string-replace (recursive-convert html-tag) "**" ""))
  (define prettified-markdown (string-trim (string-replace generated-markdown #px"\n{3,}" "\n\n")))
  (define reference-links (hash-map reference-links-table (λ (link-name link-url) (~a "[" link-name "]: " link-url))))
  (~a prettified-markdown "\n\n" (string-join reference-links "\n")))

;;; ================= 相对 URL → 在线文档 URL =================

(define (make-proper-url-for-online-documentation url [docs-path #f])
  (define online-docs-url "https://docs.racket-lang.org/")
  (define (absolute-web-url? url) (and (string-contains? url "://") (not (string-prefix? url "file"))))
  (define (get-relative-docs-url url) ; 如 "reference/module.html#(form._...)"
    (last (string-split url #rx"/doc/(racket/)?"))) ; "(racket/)?" 兼容 linux 的 usr/share/doc/racket
  (define (strip-off-last-path-segment url) (string-join (drop-right (string-split url "/") 1) "/" #:after-last "/"))
  (define (encode-url url-string)
    (define url-struct (string->url url-string))
    ;; 重点编码 Markdown 里 (, ) 和 ~：VSCode / Atom 的 Md 解析器不喜欢。
    (current-url-encode-mode 'unreserved)
    (define encoded-url (string-replace (url->string url-struct) "~" "%7E"))
    (string-replace encoded-url "&amp;" "&"))

  (define encoded-url (encode-url url))
  (cond
    [(absolute-web-url? encoded-url) encoded-url]
    [docs-path
     (define ending (get-relative-docs-url docs-path))
     (~a online-docs-url
         (if (or (string-prefix? encoded-url "#") (zero? (string-length encoded-url)))
             ending
             (strip-off-last-path-segment ending))
         encoded-url)]
    [else (~a online-docs-url (get-relative-docs-url encoded-url))]))

;;; ================= 抽取 =================

;; `docs-uri` 例："file:///.../doc/reference/define.html#(form._((lib._racket%2Fprivate%2Fbase..rkt)._define))"
(define (extract-documentation docs-uri include-signature?)
  (define url (string->url docs-uri))
  (define doc-element-name (url-fragment url))
  (define html-file-path (string-join (map path/param-path (url-path url)) "/")) ; 用于解析文档内相对 URL

  (define maybe-html-file
    (with-handlers ([exn:fail:filesystem? (λ _ #f)])
      (open-input-file (url->path url))))

  (cond [(and maybe-html-file doc-element-name)
         (define doc-xexp (html->xexp maybe-html-file)) ; html-parsing 解析
         (close-input-port maybe-html-file)

         ;; 抽取流程：
         ;; 先找选中元素文档的第一个节点（99.99% 是含 <a name=...> 的 <div class=SIntrapara>，
         ;; 里面也有函数签名）。然后顺序收集到边界节点（下一个函数 / 方法等文档开头）。
         (define cursor-at-signature (find-doc-beginning-and-take-cursor doc-xexp doc-element-name))
         (cond [cursor-at-signature
                ;; 文档可能相互嵌套。若签名 div 位于 <blockquote> 内，则视为 `nested`。
                ;; nested 时遇到下一个文档要停；非 nested 时把嵌套文档也一并收下。
                (define doc-is-nested? (cursor-go-up-until-true cursor-at-signature is-blockquote-leftindent?))

                (define cursor-after-signature (cursor-go-to-next-sibling-or-uncle-node cursor-at-signature doc-is-nested?))
                (define doc-without-signature-html (collect-docs cursor-after-signature doc-is-nested?))
                (define doc-without-signature-markdown (html->markdown doc-without-signature-html html-file-path))

                (~a (if include-signature?
                        (~a (html->markdown (cursor-selected-node cursor-at-signature) html-file-path) "\n---\n") "")
                    doc-without-signature-markdown)]
               [else #f])]
        [else #f]))

(define weak-cache (make-weak-hash))
(define (extract-documentation-for-selected-element docs-uri #:include-signature? include-signature?)
  (hash-ref! weak-cache (cons docs-uri include-signature?)
             (thunk (extract-documentation docs-uri include-signature?))))
