#lang racket

;;; app/slot.rkt —— 底部共享槽：状态栏 / 输入栏的**容器机制**
;;;
;;; 一个 layout leaf（role='slot'）同时是多个**内存文档 view** 的容器（members）；
;;; 同一时刻只挂一个 member 的 view —— 于是状态栏和输入栏“共享同一位置”。
;;; 切换 = 把该 leaf 的 view 换成目标 member 的 view（tree-set-view）。
;;;
;;; 槽状态（leaf id + member 表 + 进入输入栏前的焦点）存 world.ext（纯、可重放）。
;;; 约定：成员键 'status = 状态栏，'input = 输入栏。
;;;
;;; 本模块只管“容器 / 切换”；状态栏文本投影在 status.rkt，输入会话在 minibuffer.rkt。

(require "../layout/main.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "intent.rkt")

(provide (struct-out slot)
         slot-install slot-of slot-member slot-active
         slot-mount slot-focus-input slot-focus-status slot-focused?
         slot-show slot-show-status slot-show-input)

(define slot-key 'slot)                              ; world.ext 里的保留键

(struct slot (leaf-id members prev-focus) #:transparent)
;; leaf-id    : leaf id（role='slot'）
;; members    : (hash/c symbol view)        成员键 → view
;; prev-focus : panel-ref | #f               进入输入栏前的焦点（回状态栏时恢复）

;;; ---------- 安装 / 查询 ----------

;; 安装：把 leaf-id 槽的成员表存进 world.ext，并默认显示第一个成员。
;; members : (listof (cons key view))，第一项 = 默认显示项。
(define (slot-install w leaf-id members)
  (define tbl (for/hash ([m (in-list members)]) (values (car m) (cdr m))))
  (slot-mount (world-ext-set w slot-key (slot leaf-id tbl #f)) (caar members)))

(define (slot-of w) (world-ext-ref w slot-key #f))

(define (slot-member w key)
  (define s (slot-of w))
  (and s (hash-ref (slot-members s) key #f)))

;; 当前挂的是哪个成员（按 view 身份反查）。
(define (slot-active w)
  (define s (slot-of w))
  (define v (and s (world-ref->view w (leaf-ref (slot-leaf-id s)))))
  (and s (for/first ([(k mv) (in-hash (slot-members s))] #:when (eq? mv v)) k)))

;; 焦点是否在槽上（status / input 成员）。
(define (slot-focused? w)
  (define s (slot-of w))
  (define f (world-focus w))
  (and s f (eq? (panel-ref-kind f) 'leaf) (eqv? (panel-ref-id f) (slot-leaf-id s))))

;;; ---------- 挂载（纯） ----------

(define (slot-mount w key)
  (define s (slot-of w))
  (define v (and s (hash-ref (slot-members s) key #f)))
  (if (and s v)
      (world-set-layout w (tree-set-view (world-layout w) (slot-leaf-id s) v))
      w))

;;; ---------- 焦点转移（纯） ----------

;; 切到输入栏：记住当前焦点（若不是槽），聚焦槽（可以开始打字）。
(define (slot-focus-input w)
  (define s (slot-of w))
  (cond
    [(not s) w]
    [else
     (define lid (slot-leaf-id s))
     (define f (world-focus w))
     (define pf (if (and f (eq? (panel-ref-kind f) 'leaf) (eqv? (panel-ref-id f) lid))
                    (slot-prev-focus s)      ; 已在槽里 → 保留旧焦点
                    f))
     (world-focus-on
      (world-ext-set (slot-mount w 'input) slot-key (struct-copy slot s [prev-focus pf]))
      (leaf-ref lid))]))

;; 切回状态栏：恢复进入前的焦点。
(define (slot-focus-status w)
  (define s (slot-of w))
  (if s
      (world-focus-on (slot-mount w 'status) (slot-prev-focus s))
      w))

;;; ---------- 切换（op，返回 intent） ----------

;; 只换显示（不动焦点）。
(define (slot-show key)   (list (modify (λ (w) (slot-mount w key)))))
(define (slot-show-input) (list (modify slot-focus-input)))
(define (slot-show-status)(list (modify slot-focus-status)))
