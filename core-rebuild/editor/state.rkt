#lang racket

;;; editor/state.rkt —— buffer / view 对象 + 结构手术
;;;
;;;   buffer = 一份内容 + 历史 + 共享它的所有 view      （身份 = 对象本身）
;;;   view   = 一块显示状态（viewport + selections），指回它的 buffer（身份 = 对象本身）
;;;
;;; 宿主持有这些对象；core 不集中管理多个文档，也没有 id。
;;; 对象可以不纯：字段用 #:mutable（结构手术 / 编辑就地写）。

(require "history.rkt"
         "../text/document.rkt"
         "../text/base/track.rkt"
         "../text/base/point.rkt"
         "../text/base/selection.rkt"
         "../view/base/viewport.rkt")

(provide
 ;; ---------- 类型 ----------
 (struct-out buffer)               ; name / history / views / merge
 (struct-out view)                 ; buffer / viewport / selections

 ;; ---------- 构造 ----------
 make-buffer                       ; text [name] → buffer
 buffer-add-view!                  ; buffer w h → view（登记进 buffer.views）
 buffer-close-view!                ; buffer view → 摘掉该 view
 buffer-close!                     ; buffer → 解除与所有 view 的关联

 ;; ---------- buffer 读 / 写 ----------
 buffer-document                   ; buffer → 当前 document
 buffer-set-name!                  ; buffer name → void

 ;; ---------- view 读 / 写 ----------
 view-document                     ; view → 当前 document（buffer→history→current）

 ;; ---------- 多态入口：string | document → document ----------
 ->document)                       ; x chunk-lines → document

;;; ---------- 对象 ----------

;; 共享单元：一份内容 + 历史 + 它的所有 view。身份 = 对象本身（替代 did）。
(struct buffer (name history views merge) #:mutable)
;; name    : string
;; history : history        （current 就是当前 document 真身）
;; views   : (listof view)  共享这份内容的视图
;; merge   : #f | (list tag view selections)  会话层「并步记忆」（见 ops.rkt）

;; 视图：显示状态，指回 buffer。身份 = 对象本身（替代 vid）。
(struct view (buffer viewport selections) #:mutable)

;;; ---------- 多态入口 ----------

(define (->document x chunk-lines)
  (if (document? x) x (document-open x chunk-lines)))

;;; ---------- 构造 ----------

(define default-name "*scratch*")

;; 文首光标。
(define (initial-selections) (selections-one (caret (point 0 0))))

(define (make-buffer text [name default-name]
                     #:chunk-lines [chunk-lines default-chunk-lines]
                     #:history-limit [history-limit default-history-limit]
                     #:history? [history? #t])
  (buffer name
          (history-open (->document text chunk-lines) history-limit history?)
          '()
          #f))

;; 建一个视图挂到 buffer 上；返回新 view。
(define (buffer-add-view! b width height
                          #:mode [mode 'clip]
                          #:line-numbers? [line-numbers? #f]
                          #:selections [sels (initial-selections)])
  (define v (view b (viewport-open width height mode line-numbers?) sels))
  (set-buffer-views! b (append (buffer-views b) (list v)))
  v)

;; 摘掉一个视图（不删 buffer）。
(define (buffer-close-view! b v)
  (set-buffer-views! b
    (for/list ([x (in-list (buffer-views b))] #:unless (eq? x v)) x)))

;; 关掉一个 buffer：解除与所有 view 的关联（对象本身由宿主丢引用后回收）。
(define (buffer-close! b)
  (set-buffer-views! b '())
  (set-buffer-merge! b #f))

;;; ---------- buffer 读 / 写 ----------

(define (buffer-document b) (history-document (buffer-history b)))
(define (buffer-set-name! b n) (set-buffer-name! b n))

;;; ---------- view 读 / 写 ----------

(define (view-document v) (buffer-document (view-buffer v)))
