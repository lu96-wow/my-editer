#lang racket

;;; edit-tui/engine/store.rkt —— core buffer / view 的唯一拥有者（骨架层）
;;;
;;; 纯 State 只存 id；engine 存真正可变句柄。
;;; 命令 / step 不碰 engine，只产生 action；runtime 解释 action 时写 engine。
;;;
;;; user / ui 分开存储：
;;;   user-docs / user-views : 用户打开的文件
;;;   ui-docs   / ui-views   : status / filetree / input / completion / docs
;;;
;;; store 只负责 engine 生命周期和查询；UI 写回在 ui-projection.rkt，
;;; view-action 解释在 apply.rkt。插件通过 editor/api.rkt 的 ed 级查询访问。

(require "../../../core/editor.rkt")

(provide (struct-out engine)
         make-engine
         engine-view-object
         engine-create-buffer! engine-create-view! engine-create-view-from-view!
         engine-remove-view! engine-remove-doc!
         engine-view-text engine-doc-text engine-doc-version engine-view-doc-id
         engine-doc-kind engine-view-kind
         engine-doc-ids engine-user-doc-ids engine-ui-doc-ids
         engine-user-view-ids engine-ui-view-ids
         engine-view-ids-for-doc
         engine-view-point-line engine-view-point-column
         engine-view-cursor-screen-position
         engine-view-face-at
)

(struct engine
  (user-docs   ; did -> buffer
   ui-docs     ; did -> buffer
   user-views  ; vid -> view
   ui-views    ; vid -> view
   ui          ; vid -> (cons lines faces)：上次写进 core view 的内容
   face-track-cache) ; vid -> (cons key face-track)
  #:mutable)
;; ui / face-track-cache 都是「写回幂等」缓存——内容 / face 没变就不碰 document
;; （否则每帧都换 document revision、让 render cache 失效，filetree 上千行时
;; 一帧几十毫秒）。

(define (make-engine)
  (engine (hash) (hash) (hash) (hash) (hash) (hash)))

;;; ════════════════ 内部查找 ════════════════

;; → (values buffer kind) | (values #f #f)
(define (doc-entry e did)
  (cond
    [(hash-ref (engine-user-docs e) did #f)
     (values (hash-ref (engine-user-docs e) did) 'user)]
    [(hash-ref (engine-ui-docs e) did #f)
     (values (hash-ref (engine-ui-docs e) did) 'ui)]
    [else (values #f #f)]))

;; → (values view kind) | (values #f #f)
(define (view-entry e vid)
  (cond
    [(hash-ref (engine-user-views e) vid #f)
     (values (hash-ref (engine-user-views e) vid) 'user)]
    [(hash-ref (engine-ui-views e) vid #f)
     (values (hash-ref (engine-ui-views e) vid) 'ui)]
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
        did)))

(define (set-view! e vid v kind)
  (case kind
    [(user) (set-engine-user-views! e (hash-set (engine-user-views e) vid v))]
    [(ui) (set-engine-ui-views! e (hash-set (engine-ui-views e) vid v))]
    [else (error 'set-view! "未知 doc kind：~a" kind)]))

(define (remove-view-entry! e vid kind)
  (case kind
    [(user) (set-engine-user-views! e (hash-remove (engine-user-views e) vid))]
    [(ui) (set-engine-ui-views! e (hash-remove (engine-ui-views e) vid))]
    [else (void)])
  (set-engine-ui! e (hash-remove (engine-ui e) vid))
  (set-engine-face-track-cache! e (hash-remove (engine-face-track-cache e) vid)))

;;; ════════════════ 创建 ════════════════

(define (engine-create-buffer! e did name text #:kind [kind 'user])
  (unless (memq kind '(user ui))
    (raise-argument-error 'engine-create-buffer! "(or/c 'user 'ui)" kind))
  (define b (make-buffer text name))
  (case kind
    [(user) (set-engine-user-docs! e (hash-set (engine-user-docs e) did b))]
    [(ui) (set-engine-ui-docs! e (hash-set (engine-ui-docs e) did b))]
    [else (void)])
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
    (define views (case kind
                    [(user) (engine-user-views e)]
                    [(ui) (engine-ui-views e)]
                    [else (hash)]))
    (define vids
      (for/list ([(vid v) (in-hash views)]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (case kind
      [(user) (set-engine-user-docs! e (hash-remove (engine-user-docs e) did))]
      [(ui) (set-engine-ui-docs! e (hash-remove (engine-ui-docs e) did))]
      [else (void)]))
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
          (hash-keys (engine-ui-docs e))))

(define (engine-user-doc-ids e)
  (hash-keys (engine-user-docs e)))

(define (engine-ui-doc-ids e)
  (hash-keys (engine-ui-docs e)))

(define (engine-user-view-ids e)
  (hash-keys (engine-user-views e)))

(define (engine-ui-view-ids e)
  (hash-keys (engine-ui-views e)))

(define (engine-view-ids-for-doc e did)
  (define-values (b kind) (doc-entry e did))
  (cond
    [(not b) #f]
    [else
     (define views (case kind
                     [(user) (engine-user-views e)]
                     [(ui) (engine-ui-views e)]
                     [else (hash)]))
     (for/list ([(vid v) (in-hash views)]
                #:when (eq? (view-buffer v) b))
       vid)]))

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
