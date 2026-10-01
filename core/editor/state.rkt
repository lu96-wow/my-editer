#lang racket

(require "../text/document.rkt" "history.rkt" "../text/base/track.rkt"
         "../view/base/viewport.rkt" "../text/base/selection.rkt" "../text/base/point.rkt")

;;; editor/state.rkt —— editor 数据 + 查找
;;;
;;;   editor         = documents × views
;;;   document-entry = id ⊕ name ⊕ history
;;;   view           = id ⊕ did ⊕ viewport ⊕ selections
;;;
;;; **editor 不持焦点**：哪个 view 当前被操作由宿主决定，接口一律显式 vid/did。
;;;
;;; document-entry 不另存一份 document：当前文档就是 history 的 current 快照
;;; （单一事实源，避免与撤销账本各存一份而失同步）。
;;;
;;; 一个 document 可被多个 view 看；history 属于 **document**（多 view 共享），
;;; 一步记发起 vid（history 的 who），撤销时把选区还原到发起视图。
;;; 本模块只有数据、查找、构造，以及**安全**写口（只改一个字段，不破坏结构一致）。
;;; 能破坏不变量的低层写口（换整个 view / 换 history）在 write.rkt，
;;; 不进 editor.rkt 标准入口。

(provide
 ;; ---------- 类型 ----------
 (struct-out document-entry)
 (struct-out view)
 (struct-out editor)

 ;; ---------- 构造 / 生命周期 ----------
 editor-open
 editor-add-document
 editor-add-view
 editor-add-document-view
 editor-document-set-name
 editor-close-view
 editor-close-document

 ;; ---------- 查找 / 访问 ----------
 document-entry-document
 editor-document-entry
 editor-view-ref
 editor-view-document
 editor-document-history
 document-id-of
 first-view-of-document

 ;; ---------- 安全写口（只改一个字段） ----------
 editor-view-set-sync
 editor-view-set-link
 editor-view-set-history-enabled)

;;; ---------- 数据 ----------

(struct document-entry (id name history) #:transparent)
;; history : history    撤销账本（快照栈），同时**持有当前文档**（单一事实源）

(struct view (id did viewport selections sync link) #:transparent)
;; id : nat；did : nat；viewport : viewport；selections : selections
;; sync : 'free | 'follow   同文档视口跟随：本视图跟随「发起视图」的视口
;; link : #f | any/c        跨文档视口同步组键：键相等的视图互相跟随

(struct editor (documents views next-document next-view clipboard) #:transparent)
;; documents / views 顺序稳定；next-* 是下一个要分配的号
;; clipboard : (or/c #f clipboard?)   跨文档剪贴板；#f = 空

;;; ---------- 构造 ----------

(define default-name "*scratch*")

(define (check-sync who s)
  (unless (memq s '(free follow))
    (error who "sync 必须是 'free / 'follow，得到 ~a" s)))

;; 新视图 / 新文档的初始选区：文首光标。
(define (initial-selections) (selections-one (caret (point 0 0))))

;; 入口多态：string → 现开纯文本文档；document → 原样使用（带属性）。
(define (->document x chunk-lines)
  (if (document? x) x (document-open x chunk-lines)))

;; 一个文档 + 一个视图。text 可以是 string（现开一个文档）或现成的 document（带属性，原样使用）。
;; #:mode / #:line-numbers?  视图初始 clip/wrap、是否开行号
;; #:chunk-lines            仅当 text 是 string：底层轨的分块行数（默认 512）
;; #:history-limit          撤销栈深度上限（默认 1000）
;; #:history?               是否记步（默认 #t；widget 可 #f，编辑不进撤销栈）
(define (editor-open text width height [name default-name]
                     #:mode [mode 'clip]
                     #:line-numbers? [line-numbers? #f]
                     #:chunk-lines [chunk-lines default-chunk-lines]
                     #:history-limit [history-limit default-history-limit]
                     #:history? [history? #t])
  (define doc (->document text chunk-lines))
  (define sels (initial-selections))
  (editor (list (document-entry 0 name (history-open doc sels history-limit history?)))
          (list (view 0 0 (viewport-open width height mode line-numbers?) sels 'free #f))
          1 1 #f))

;; 给已有文档加一个视图。sync='follow 时跟随同文档的发起视图。→ (values editor vid)
;; #:mode / #:line-numbers? 视图初始 clip/wrap、是否开行号。
(define (editor-add-view ed did width height [sync 'free] [link #f]
                         #:mode [mode 'clip]
                         #:line-numbers? [line-numbers? #f])
  (check-sync 'editor-add-view sync)
  (editor-document-entry ed did)                    ; 校验 did
  (define vid (editor-next-view ed))
  (values
   (struct-copy editor ed
     [views (append (editor-views ed)
                    (list (view vid did (viewport-open width height mode line-numbers?)
                                (initial-selections) sync link)))]
     [next-view (add1 vid)])
   vid))

;; 一步建"文档 + 视图"（通用：文档 + 它的一个视图）。→ (values editor did vid)
(define (editor-add-document-view ed text width height [name default-name]
                                  #:mode [mode 'clip]
                                  #:line-numbers? [line-numbers? #f]
                                  #:sync [sync 'free]
                                  #:link [link #f]
                                  #:chunk-lines [chunk-lines default-chunk-lines]
                                  #:history-limit [history-limit default-history-limit]
                                  #:history? [history? #t])
  (define-values (ed* did)
    (editor-add-document ed text name
                         #:chunk-lines chunk-lines #:history-limit history-limit #:history? history?))
  (define-values (ed** vid)
    (editor-add-view ed* did width height sync link #:mode mode #:line-numbers? line-numbers?))
  (values ed** did vid))

;; 新增一个文档（不建视图；要显示时再 editor-add-view）。→ (values editor did)
;; text 可为 string（现开）或现成 document（带属性；#:chunk-lines 忽略）。
(define (editor-add-document ed text [name default-name]
                             #:chunk-lines [chunk-lines default-chunk-lines]
                             #:history-limit [history-limit default-history-limit]
                             #:history? [history? #t])
  (define doc (->document text chunk-lines))
  (define sels (initial-selections))
  (define did (editor-next-document ed))
  (values (struct-copy editor ed
            [documents (append (editor-documents ed)
                               (list (document-entry did name (history-open doc sels history-limit history?))))]
            [next-document (add1 did)])
          did))

;;; ---------- 查找 ----------

;; 某个 document-entry 的当前文档：取 history 的 current 快照（不另存一份）。
(define (document-entry-document e)
  (history-document (document-entry-history e)))

(define (editor-document-entry ed did)
  (or (for/first ([e (in-list (editor-documents ed))] #:when (= did (document-entry-id e))) e)
      (error 'editor "没有这个 document id: ~a" did)))

(define (editor-view-ref ed vid)
  (or (for/first ([v (in-list (editor-views ed))] #:when (= vid (view-id v))) v)
      (error 'editor "没有这个 view id: ~a" vid)))

;; 某个视图看的 document 值。
(define (editor-view-document ed vid)
  (document-entry-document (editor-document-entry ed (view-did (editor-view-ref ed vid)))))

(define (editor-document-history ed did)
  (document-entry-history (editor-document-entry ed did)))

;; document **值** → 它在 registry 里的 id（引用完整性）。
(define (document-id-of ed d)
  (define e (for/first ([e (in-list (editor-documents ed))]
                        #:when (eq? d (document-entry-document e))) e))
  (unless e (error 'document-id-of "这个 document 不在 editor 里"))
  (document-entry-id e))

(define (first-view-of-document ed did)
  (for/first ([v (in-list (editor-views ed))] #:when (= did (view-did v))) v))

;;; ---------- 安全写口（只改一个字段） ----------

(define (map-view ed vid f)
  (editor-view-ref ed vid)                          ; 校验 vid
  (struct-copy editor ed
    [views (for/list ([x (in-list (editor-views ed))])
             (if (= vid (view-id x)) (f x) x))]))

(define (editor-view-set-sync ed vid sync)
  (check-sync 'editor-view-set-sync sync)
  (map-view ed vid (lambda (v) (struct-copy view v [sync sync]))))

(define (editor-view-set-link ed vid link)
  (map-view ed vid (lambda (v) (struct-copy view v [link link]))))

;; 开关某视图所属文档的记步（per-document；只改 history 的一个字段）。
(define (editor-view-set-history-enabled ed vid flag)
  (define did (view-did (editor-view-ref ed vid)))
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))])
                 (if (= did (document-entry-id e))
                     (struct-copy document-entry e
                                  [history (history-set-enabled (document-entry-history e) flag)])
                     e))]))

;;; ---------- 生命周期（增 / 删 / 改名） ----------

(define (editor-document-set-name ed did name)
  (editor-document-entry ed did)                    ; 校验 did
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))])
                 (if (= did (document-entry-id e)) (struct-copy document-entry e [name name]) e))]))

;; 关一个视图（焦点由宿主自理，这里不管）。
(define (editor-close-view ed vid)
  (editor-view-ref ed vid)                          ; 校验 vid
  (struct-copy editor ed
    [views (for/list ([v (in-list (editor-views ed))] #:unless (= vid (view-id v))) v)]))

;; 关一个文档：连带它的视图一起去掉（焦点由宿主自理）。
(define (editor-close-document ed did)
  (editor-document-entry ed did)                    ; 校验 did
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))] #:unless (= did (document-entry-id e))) e)]
    [views (for/list ([v (in-list (editor-views ed))] #:unless (= did (view-did v))) v)]))
