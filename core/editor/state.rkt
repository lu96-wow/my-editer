#lang racket

(require "../text/document.rkt" "history.rkt" "../text/base/track.rkt"
         "../view/base/viewport.rkt" "../text/base/selection.rkt" "../text/base/point.rkt")

;;; editor/state.rkt —— editor 数据 + 结构操作 + 查找
;;;
;;;   editor         = 不可变骨架(documents, views, next-*, clipboard box)
;;;   document-entry = entry-immutable(id)      ⊕ entry-mutable(name box, history box)
;;;   view           = view-immutable(id, did)   ⊕ view-mutable(viewport box,
;;;                                                            selections box)
;;;
;;; 只有 list 结构变化（增/删文档、增/删视图）产新 editor；其余就地改 box。
;;;
;;; document-entry 的当前文档就是 history 的 current 快照。

(provide
 ;; ---------- 类型 ----------
 (struct-out entry-immutable)
 (struct-out entry-mutable)
 (struct-out document-entry)
 (struct-out view-immutable)
 (struct-out view-mutable)
 (struct-out view)
 (struct-out editor)
 editor-clipboard

 ;; ---------- 绑定访问 ----------
 document-entry-id document-entry-name document-entry-history
 view-id view-did view-viewport view-selections

 ;; ---------- 构造 ----------
 make-document-entry make-view

 ;; ---------- 多态入口：string | document → document ----------
 ->document

 ;; ---------- 裸 box setter ----------
 document-entry-set-name! document-entry-set-history!
 view-set-viewport! view-set-selections!
 editor-set-clipboard!

 ;; ---------- 字段元数据写口 ----------
 editor-document-set-name!
 editor-document-set-history-enabled!

 ;; ---------- 结构操作（返回新 editor） ----------
 editor-open
 make-blank-editor
 editor-add-document
 editor-add-view
 editor-add-document-view
 editor-close-view
 editor-close-document

 ;; ---------- 查找 / 读 ----------
 document-entry-document
 editor-document-entry
 editor-view-ref
 editor-view-document
 editor-document-handle
 editor-document-history
 document-id-of
 first-view-of-document)

;;; ---------- 数据 ----------

;; 身份（不可变）
(struct entry-immutable (id) #:transparent)
(struct view-immutable (id did) #:transparent)

;; 可变状态（在 box 里）
(struct entry-mutable (name history) #:transparent)                    ; 两个 box
(struct view-mutable (viewport selections) #:transparent)               ; 两个 box

(struct document-entry (im mut) #:transparent)
(struct view (im mut) #:transparent)

(struct editor (documents views next-document next-view clipboard-box) #:transparent)
;; documents / views : 不可变列表（顺序稳定）；next-* : 分配器
;; clipboard-box : box（#f = 空）

;;; ---------- 绑定访问（读 box 内容） ----------

(define (document-entry-id e) (entry-immutable-id (document-entry-im e)))
(define (document-entry-name e) (unbox (entry-mutable-name (document-entry-mut e))))
(define (document-entry-history e) (unbox (entry-mutable-history (document-entry-mut e))))

(define (view-id v) (view-immutable-id (view-im v)))
(define (view-did v) (view-immutable-did (view-im v)))
(define (view-viewport v) (unbox (view-mutable-viewport (view-mut v))))
(define (view-selections v) (unbox (view-mutable-selections (view-mut v))))

(define (editor-clipboard ed) (unbox (editor-clipboard-box ed)))

;;; ---------- 裸 box setter（改 box 内容） ----------

(define (document-entry-set-name! e n)
  (set-box! (entry-mutable-name (document-entry-mut e)) n))
(define (document-entry-set-history! e h)
  (set-box! (entry-mutable-history (document-entry-mut e)) h))

(define (view-set-viewport! v vp) (set-box! (view-mutable-viewport (view-mut v)) vp))
(define (view-set-selections! v s) (set-box! (view-mutable-selections (view-mut v)) s))

(define (editor-set-clipboard! ed c) (set-box! (editor-clipboard-box ed) c))

;;; ---------- 字段元数据写口 ----------

(define (editor-document-set-name! ed did name)
  (document-entry-set-name! (editor-document-entry ed did) name))

;; history 是文档级属性，开关按 did。
(define (editor-document-set-history-enabled! ed did flag)
  (document-entry-set-history! (editor-document-entry ed did)
                               (history-set-enabled (editor-document-history ed did) flag)))

;;; ---------- 构造（单条 entry / view，建 box） ----------

(define (make-document-entry id name history)
  (document-entry (entry-immutable id) (entry-mutable (box name) (box history))))
(define (make-view id did viewport selections)
  (view (view-immutable id did)
        (view-mutable (box viewport) (box selections))))

;;; ---------- 构造（editor） ----------

(define default-name "*scratch*")

;; 新视图 / 新文档的初始选区：文首光标。
(define (initial-selections) (selections-one (caret (point 0 0))))

;; 入口多态：string → 现开纯文本文档；document → 原样使用（带属性）。
(define (->document x chunk-lines)
  (if (document? x) x (document-open x chunk-lines)))

;; 空 editor：无文档、无视图。
(define (make-blank-editor)
  (editor '() '() 0 0 (box #f)))

(define (editor-open text width height [name default-name]
                     #:mode [mode 'clip]
                     #:line-numbers? [line-numbers? #f]
                     #:chunk-lines [chunk-lines default-chunk-lines]
                     #:history-limit [history-limit default-history-limit]
                     #:history? [history? #t])
  (define doc (->document text chunk-lines))
  (define sels (initial-selections))
  (editor (list (make-document-entry 0 name (history-open doc sels history-limit history?)))
          (list (make-view 0 0 (viewport-open width height mode line-numbers?) sels))
          1 1 (box #f)))

;; 给已有文档加一个视图。→ (values editor vid)
(define (editor-add-view ed did width height
                         #:mode [mode 'clip]
                         #:line-numbers? [line-numbers? #f])
  (editor-document-entry ed did)                    ; 校验 did
  (define vid (editor-next-view ed))
  (values
   (struct-copy editor ed
     [views (append (editor-views ed)
                    (list (make-view vid did (viewport-open width height mode line-numbers?)
                                     (initial-selections))))]
     [next-view (add1 vid)])
   vid))

;; 一步建"文档 + 视图"。→ (values editor did vid)
(define (editor-add-document-view ed text width height [name default-name]
                                  #:mode [mode 'clip]
                                  #:line-numbers? [line-numbers? #f]
                                  #:chunk-lines [chunk-lines default-chunk-lines]
                                  #:history-limit [history-limit default-history-limit]
                                  #:history? [history? #t])
  (define-values (ed* did)
    (editor-add-document ed text name
                         #:chunk-lines chunk-lines #:history-limit history-limit #:history? history?))
  (define-values (ed** vid)
    (editor-add-view ed* did width height #:mode mode #:line-numbers? line-numbers?))
  (values ed** did vid))

;; 新增一个文档（不建视图）。→ (values editor did)
(define (editor-add-document ed text [name default-name]
                             #:chunk-lines [chunk-lines default-chunk-lines]
                             #:history-limit [history-limit default-history-limit]
                             #:history? [history? #t])
  (define doc (->document text chunk-lines))
  (define sels (initial-selections))
  (define did (editor-next-document ed))
  (values (struct-copy editor ed
            [documents (append (editor-documents ed)
                               (list (make-document-entry did name
                                                          (history-open doc sels history-limit history?))))]
            [next-document (add1 did)])
          did))

;;; ---------- 查找 ----------

(define (document-entry-document e)
  (history-document (document-entry-history e)))

(define (editor-document-entry ed did)
  (or (for/first ([e (in-list (editor-documents ed))] #:when (= did (document-entry-id e))) e)
      (error 'editor "没有这个 document id: ~a" did)))

(define (editor-view-ref ed vid)
  (or (for/first ([v (in-list (editor-views ed))] #:when (= vid (view-id v))) v)
      (error 'editor "没有这个 view id: ~a" vid)))

(define (editor-view-document ed vid)
  (document-entry-document (editor-document-entry ed (view-did (editor-view-ref ed vid)))))

;; 按 did 取当前文档句柄。
(define (editor-document-handle ed did)
  (document-entry-document (editor-document-entry ed did)))

(define (editor-document-history ed did)
  (document-entry-history (editor-document-entry ed did)))

(define (document-id-of ed d)
  (define e (for/first ([e (in-list (editor-documents ed))]
                        #:when (eq? d (document-entry-document e))) e))
  (unless e (error 'document-id-of "这个 document 不在 editor 里"))
  (document-entry-id e))

(define (first-view-of-document ed did)
  (for/first ([v (in-list (editor-views ed))] #:when (= did (view-did v))) v))

;;; ---------- 生命周期（删） ----------

;; 关一个视图。
(define (editor-close-view ed vid)
  (editor-view-ref ed vid)                          ; 校验 vid
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))] #:unless (= vid (view-id v))) v)]))

;; 关一个文档：连带它的视图一起去掉。
(define (editor-close-document ed did)
  (editor-document-entry ed did)                    ; 校验 did
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))] #:unless (= did (document-entry-id e))) e)]
    [views (for/list ([v (in-list (editor-views ed))] #:unless (= did (view-did v))) v)]))
