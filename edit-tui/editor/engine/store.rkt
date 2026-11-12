#lang racket

;;; edit-tui/engine/store.rkt —— core buffer / view 的唯一拥有者（骨架层）
;;;
;;; 纯 State 只存 id；engine 存真正可变句柄。
;;; 命令 / step 不碰 engine，只产生 action；runtime 解释 action 时写 engine。
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
         engine-doc-kind engine-doc-ids engine-user-doc-ids engine-ui-doc-ids
         engine-view-ids-for-doc
         engine-view-point-line engine-view-point-column
         engine-view-cursor-screen-position
         engine-view-face-at
)

(struct engine (docs doc-kinds views ui face-track-cache) #:mutable)
;; docs      : did -> buffer
;; doc-kinds : did -> 'user | 'ui
;; ui        : vid -> (cons lines faces)：上次写进 core view 的内容。
;; face-track-cache : vid -> (cons key face-track)：上次写进 editor view 的逐字符 face。
;;
;; 两者都是「写回幂等」缓存——内容 / face 没变就不碰 document（否则每帧都换
;; document revision、让 render cache 失效，filetree 上千行时一帧几十毫秒）。

(define (make-engine)
  (engine (hash) (hash) (hash) (hash) (hash)))

(define (engine-doc-buffer e did)
  (hash-ref (engine-docs e) did #f))

(define (engine-view-object e vid)
  (hash-ref (engine-views e) vid #f))

(define (engine-create-buffer! e did name text #:kind [kind 'user])
  (unless (memq kind '(user ui))
    (raise-argument-error 'engine-create-buffer! "(or/c 'user 'ui)" kind))
  (define b (make-buffer text name))
  (set-engine-docs! e (hash-set (engine-docs e) did b))
  (set-engine-doc-kinds! e (hash-set (engine-doc-kinds e) did kind))
  b)

(define (engine-create-view! e vid did)
  (define b (engine-doc-buffer e did))
  (unless b (error 'engine-create-view! "doc 不存在：~a" did))
  (define v (buffer-add-view! b 1 1))
  (set-engine-views! e (hash-set (engine-views e) vid v))
  v)

;; 从已有 view 克隆一个新 view（同一 buffer / document / history）。
;; 用于 split：新 panel 需要自己的 view，不能把一个 view 同时挂到两个 panel。
(define (engine-create-view-from-view! e new-vid source-vid)
  (define src (engine-view-object e source-vid))
  (unless src (error 'engine-create-view-from-view! "source view 不存在：~a" source-vid))
  (define v (buffer-add-view! (view-buffer src) 1 1
                              #:selections (view-selections src)))
  (set-engine-views! e (hash-set (engine-views e) new-vid v))
  v)

(define (engine-remove-view! e vid)
  (define v (engine-view-object e vid))
  (when v
    (buffer-close-view! (view-buffer v) v)
    (set-engine-views! e (hash-remove (engine-views e) vid))
    (set-engine-ui! e (hash-remove (engine-ui e) vid))
    (set-engine-face-track-cache! e (hash-remove (engine-face-track-cache e) vid)))
  (void))

(define (engine-remove-doc! e did)
  (define b (engine-doc-buffer e did))
  (when b
    (define vids
      (for/list ([(vid v) (in-hash (engine-views e))]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (set-engine-docs! e (hash-remove (engine-docs e) did))
    (set-engine-doc-kinds! e (hash-remove (engine-doc-kinds e) did)))
  (void))

(define (engine-view-text e vid)
  (define v (engine-view-object e vid))
  (and v (view-string v)))

;; view 所属的 doc-id；UI view（无 buffer）-> #f。
(define (engine-view-doc-id e vid)
  (define v (engine-view-object e vid))
  (and v
       (for/first ([did (in-hash-keys (engine-docs e))]
                   #:when (eq? (engine-doc-buffer e did) (view-buffer v)))
         did)))

(define (engine-doc-kind e did)
  (hash-ref (engine-doc-kinds e) did #f))

(define (engine-doc-ids e)
  (hash-keys (engine-docs e)))

(define (engine-user-doc-ids e)
  (for/list ([(did _b) (in-hash (engine-docs e))]
             #:when (eq? (engine-doc-kind e did) 'user))
    did))

(define (engine-ui-doc-ids e)
  (for/list ([(did _b) (in-hash (engine-docs e))]
             #:when (eq? (engine-doc-kind e did) 'ui))
    did))

(define (engine-view-ids-for-doc e did)
  (define b (engine-doc-buffer e did))
  (and b
       (for/list ([(vid v) (in-hash (engine-views e))]
                  #:when (eq? (view-buffer v) b))
         vid)))

(define (engine-doc-text e did)
  (define b (engine-doc-buffer e did))
  (and b (buffer-string b)))

(define (engine-doc-version e did)
  (define b (engine-doc-buffer e did))
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
