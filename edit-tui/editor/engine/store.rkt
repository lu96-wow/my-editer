#lang racket

;;; edit-tui/engine/store.rkt —— core buffer / view 的唯一拥有者（骨架层）
;;;
;;; 纯 State 只存 id；engine 存真正可变句柄。
;;; 命令 / step 不碰 engine，只产生 action；runtime 解释 action 时写 engine。
;;;
;;; 文档分三类：
;;;   user-docs / user-views       : 用户打开的文件
;;;   ui-docs / ui-views           : status / filetree / input / completion / docs
;;;   derived-docs / derived-views : 插件拥有的派生文本（无 resource / 无 history）
;;;
;;; derived 文档带 derived-meta：owner / source-doc-id / edit-policy。
;;; 它不进入 user-doc 查询；用户编辑是否允许由 edit-policy 决定。
;;;
;;; store 只负责 engine 生命周期和查询；UI / derived 投影写回在
;;; projection-write.rkt，view-action 解释在 apply.rkt。

(require "../../../core/editor.rkt")

(provide (struct-out engine)
         (struct-out derived-meta)
         make-engine
         engine-view-object
         engine-create-buffer! engine-create-view! engine-create-view-from-view!
         engine-remove-view! engine-remove-doc!
         engine-view-text engine-doc-text engine-doc-version engine-view-doc-id
         engine-doc-kind engine-view-kind
         engine-doc-ids engine-user-doc-ids engine-ui-doc-ids engine-derived-doc-ids
         engine-user-view-ids engine-ui-view-ids engine-derived-view-ids
         engine-view-ids-for-doc
         engine-derived-doc-owner engine-derived-doc-source
         engine-derived-doc-edit-policy
         engine-view-point-line engine-view-point-column
         engine-view-cursor-screen-position
         engine-view-face-at)

;; owner          : plugin-id
;; source-doc-id  : doc-id | #f
;; edit-policy    : 'intent | 'read-only
(struct derived-meta (owner source-doc-id edit-policy) #:transparent)

(struct engine
  (user-docs     ; did -> buffer
   ui-docs       ; did -> buffer
   derived-docs  ; did -> buffer
   user-views    ; vid -> view
   ui-views      ; vid -> view
   derived-views ; vid -> view
   derived-meta  ; did -> derived-meta
   projection-cache ; vid -> (cons lines faces)：上次投影内容
   face-track-cache) ; vid -> (cons key face-track)
  #:mutable)
;; projection-cache / face-track-cache 都是「写回幂等」缓存——内容 / face 没变
;; 就不碰 document（否则每帧都换 document revision、让 render cache 失效）。
;; 缓存键是 view-id，UI / derived / user view 共用；语义区分在写入口。

(define (make-engine)
  (engine (hash) (hash) (hash)
          (hash) (hash) (hash)
          (hash) (hash) (hash)))

;;; ════════════════ 内部查找 ════════════════

(define (docs-of e kind)
  (case kind
    [(user) (engine-user-docs e)]
    [(ui) (engine-ui-docs e)]
    [(derived) (engine-derived-docs e)]
    [else #f]))

(define (views-of e kind)
  (case kind
    [(user) (engine-user-views e)]
    [(ui) (engine-ui-views e)]
    [(derived) (engine-derived-views e)]
    [else #f]))

(define (set-docs-of! e kind h)
  (case kind
    [(user) (set-engine-user-docs! e h)]
    [(ui) (set-engine-ui-docs! e h)]
    [(derived) (set-engine-derived-docs! e h)]
    [else (error 'set-docs-of! "未知 doc kind：~a" kind)]))

(define (set-views-of! e kind h)
  (case kind
    [(user) (set-engine-user-views! e h)]
    [(ui) (set-engine-ui-views! e h)]
    [(derived) (set-engine-derived-views! e h)]
    [else (error 'set-views-of! "未知 view kind：~a" kind)]))

;; → (values buffer kind) | (values #f #f)
(define (doc-entry e did)
  (cond
    [(hash-ref (engine-user-docs e) did #f)
     (values (hash-ref (engine-user-docs e) did) 'user)]
    [(hash-ref (engine-ui-docs e) did #f)
     (values (hash-ref (engine-ui-docs e) did) 'ui)]
    [(hash-ref (engine-derived-docs e) did #f)
     (values (hash-ref (engine-derived-docs e) did) 'derived)]
    [else (values #f #f)]))

;; → (values view kind) | (values #f #f)
(define (view-entry e vid)
  (cond
    [(hash-ref (engine-user-views e) vid #f)
     (values (hash-ref (engine-user-views e) vid) 'user)]
    [(hash-ref (engine-ui-views e) vid #f)
     (values (hash-ref (engine-ui-views e) vid) 'ui)]
    [(hash-ref (engine-derived-views e) vid #f)
     (values (hash-ref (engine-derived-views e) vid) 'derived)]
    [else (values #f #f)]))

(define (doc-buffer e did)
  (define-values (b _kind) (doc-entry e did))
  b)

(define (doc-id-for-buffer e b)
  (or (for/first ([(did buf) (in-hash (engine-user-docs e))]
                  #:when (eq? buf b))
        did)
      (for/first ([(did buf) (in-hash (engine-ui-docs e))]
                  #:when (eq? buf b))
        did)
      (for/first ([(did buf) (in-hash (engine-derived-docs e))]
                  #:when (eq? buf b))
        did)))

(define (set-view! e vid v kind)
  (set-views-of! e kind (hash-set (views-of e kind) vid v)))

(define (remove-view-entry! e vid kind)
  (set-views-of! e kind (hash-remove (views-of e kind) vid))
  (set-engine-projection-cache! e
                                (hash-remove (engine-projection-cache e) vid))
  (set-engine-face-track-cache! e
                                (hash-remove (engine-face-track-cache e) vid)))

;;; ════════════════ 创建 ════════════════

(define (check-kind who kind)
  (unless (memq kind '(user ui derived))
    (raise-argument-error who "(or/c 'user 'ui 'derived)" kind)))

(define (engine-create-buffer! e did name text
                              #:kind [kind 'user]
                              #:owner [owner #f]
                              #:source-doc-id [source-doc-id #f]
                              #:edit-policy [edit-policy 'intent])
  (check-kind 'engine-create-buffer! kind)
  (when (eq? kind 'derived)
    (unless (symbol? owner)
      (raise-argument-error 'engine-create-buffer!
                            "derived buffer 需要 symbol? owner"
                            owner))
    (unless (memq edit-policy '(intent read-only))
      (raise-argument-error 'engine-create-buffer!
                            "(or/c 'intent 'read-only)"
                            edit-policy)))
  (when (and (not (eq? kind 'derived))
             (or owner source-doc-id))
    (error 'engine-create-buffer!
           "owner / source-doc-id 只属于 derived buffer"))
  (define b (make-buffer text name))
  (set-docs-of! e kind (hash-set (docs-of e kind) did b))
  (when (eq? kind 'derived)
    ;; derived 不是权威文档：用户编辑不记 history。
    (buffer-reset-history! b #f)
    (set-engine-derived-meta!
     e
     (hash-set (engine-derived-meta e) did
               (derived-meta owner source-doc-id edit-policy))))
  b)

(define (engine-create-view! e vid did)
  (define-values (b kind) (doc-entry e did))
  (unless b (error 'engine-create-view! "doc 不存在：~a" did))
  (define v (buffer-add-view! b 1 1))
  (set-view! e vid v kind)
  v)

;; 从已有 view 克隆一个新 view（同一 buffer / document / history）。
;; 用于 split：新 panel 需要自己的 view，不能把一个 view 同时挂到两个 panel。
(define (engine-create-view-from-view! e new-vid source-vid)
  (define-values (src kind) (view-entry e source-vid))
  (unless src (error 'engine-create-view-from-view! "source view 不存在：~a" source-vid))
  (define v (buffer-add-view! (view-buffer src) 1 1
                              #:selections (view-selections src)))
  (set-view! e new-vid v kind)
  v)

;;; ════════════════ 删除 ════════════════

(define (engine-view-object e vid)
  (define-values (v _kind) (view-entry e vid))
  v)

(define (engine-remove-view! e vid)
  (define-values (v kind) (view-entry e vid))
  (when v
    (buffer-close-view! (view-buffer v) v)
    (remove-view-entry! e vid kind))
  (void))

(define (engine-remove-doc! e did)
  (define-values (b kind) (doc-entry e did))
  (when b
    (define views (views-of e kind))
    (define vids
      (for/list ([(vid v) (in-hash views)]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (set-docs-of! e kind (hash-remove (docs-of e kind) did))
    (when (eq? kind 'derived)
      (set-engine-derived-meta! e
                                (hash-remove (engine-derived-meta e) did))))
  (void))

;;; ════════════════ 查询 / 读 ════════════════

(define (engine-view-text e vid)
  (define v (engine-view-object e vid))
  (and v (view-string v)))

;; view 所属的 doc-id；无 view -> #f。
(define (engine-view-doc-id e vid)
  (define v (engine-view-object e vid))
  (and v (doc-id-for-buffer e (view-buffer v))))

(define (engine-doc-kind e did)
  (define-values (_b kind) (doc-entry e did))
  kind)

(define (engine-view-kind e vid)
  (define-values (_v kind) (view-entry e vid))
  kind)

(define (engine-doc-ids e)
  (append (hash-keys (engine-user-docs e))
          (hash-keys (engine-ui-docs e))
          (hash-keys (engine-derived-docs e))))

(define (engine-user-doc-ids e)
  (hash-keys (engine-user-docs e)))

(define (engine-ui-doc-ids e)
  (hash-keys (engine-ui-docs e)))

(define (engine-derived-doc-ids e)
  (hash-keys (engine-derived-docs e)))

(define (engine-user-view-ids e)
  (hash-keys (engine-user-views e)))

(define (engine-ui-view-ids e)
  (hash-keys (engine-ui-views e)))

(define (engine-derived-view-ids e)
  (hash-keys (engine-derived-views e)))

(define (engine-view-ids-for-doc e did)
  (define-values (b kind) (doc-entry e did))
  (cond
    [(not b) #f]
    [else
     (define views (views-of e kind))
     (for/list ([(vid v) (in-hash views)]
                #:when (eq? (view-buffer v) b))
       vid)]))

(define (engine-derived-doc-owner e did)
  (define m (hash-ref (engine-derived-meta e) did #f))
  (and m (derived-meta-owner m)))

(define (engine-derived-doc-source e did)
  (define m (hash-ref (engine-derived-meta e) did #f))
  (and m (derived-meta-source-doc-id m)))

(define (engine-derived-doc-edit-policy e did)
  (define m (hash-ref (engine-derived-meta e) did #f))
  (and m (derived-meta-edit-policy m)))

(define (engine-doc-text e did)
  (define b (doc-buffer e did))
  (and b (buffer-string b)))

(define (engine-doc-version e did)
  (define b (doc-buffer e did))
  (and b (buffer-version b)))

(define (engine-view-point-line e vid)
  (define v (engine-view-object e vid))
  (and v (view-point-line v)))

(define (engine-view-point-column e vid)
  (define v (engine-view-object e vid))
  (and v (view-point-column v)))

;; 光标在当前 view 内的屏幕位置 (row col)；不可见 / 无 view -> #f。
(define (engine-view-cursor-screen-position e vid)
  (define v (engine-view-object e vid))
  (and v
       (let-values ([(row col) (view-cursor-screen-position v)])
         (and row (cons row col)))))

;; 供测试 / 诊断：view 某格的 face。
(define (engine-view-face-at e vid line col)
  (define v (engine-view-object e vid))
  (and v (view-face-at v line col)))
