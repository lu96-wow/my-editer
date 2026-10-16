#lang racket

;;; app/slot.rkt —— 底部共享槽：状态栏 / 输入栏（内置 chrome）
;;;
;;; 一个 layout leaf（role='slot'）同时是多个**内存文档 view** 的容器（members）；
;;; 同一时刻只挂一个 member 的 view —— 于是状态栏和输入栏“共享同一位置”。
;;; 切换 = 把该 leaf 的 view 换成目标 member 的 view（tree-set-view）。
;;;
;;; 槽状态（leaf id + member 表 + 进入输入栏前的焦点）存 world.ext（纯、可重放）。
;;; 约定：成员键 'status = 状态栏，'input = 输入栏。
;;;
;;; world.status 是逻辑状态行文本；status-sync!（不纯，loop 每帧调）把它镜像进
;;; 'status member 的 buffer —— 和 panels-sync! 同理，是“本帧显示”的一次写。

(require "../../core/editor.rkt"
         "../layout/main.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "intent.rkt")

(provide (struct-out slot)
         slot-install slot-of slot-member slot-active
         slot-show slot-show-status slot-show-input
         status-sync!)

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

;;; ---------- 挂载（纯） ----------

(define (slot-mount w key)
  (define s (slot-of w))
  (define v (and s (hash-ref (slot-members s) key #f)))
  (if (and s v)
      (world-set-layout w (tree-set-view (world-layout w) (slot-leaf-id s) v))
      w))

;;; ---------- 切换（op，返回 intent） ----------

;; 只换显示（不动焦点）。
(define (slot-show key)
  (list (modify (λ (w) (slot-mount w key)))))

;; 切到输入栏：记住当前焦点（若不是槽），再聚焦槽（可以开始打字）。
(define (slot-show-input)
  (list (modify (λ (w)
                  (define s (slot-of w))
                  (if s
                      (let* ([lid (slot-leaf-id s)]
                             [f (world-focus w)]
                             [pf (if (and f (eq? (panel-ref-kind f) 'leaf)
                                          (eqv? (panel-ref-id f) lid))
                                     (slot-prev-focus s)   ; 已在槽里 → 保留旧焦点
                                     f)])
                        (world-focus-on
                         (world-ext-set (slot-mount w 'input) slot-key
                                        (struct-copy slot s [prev-focus pf]))
                         (leaf-ref lid)))
                      w)))))

;; 切回状态栏：恢复进入前的焦点。
(define (slot-show-status)
  (list (modify (λ (w)
                  (define s (slot-of w))
                  (if s
                      (world-focus-on (slot-mount w 'status) (slot-prev-focus s))
                      w)))))

;;; ---------- 状态行同步（不纯；loop 每帧调） ----------

;; 把 world.status 镜像进 'status member 的 buffer。
(define (status-sync! w)
  (define v (slot-member w 'status))
  (when v
    (define b (view-buffer v))
    (unless (string=? (buffer-string b) (world-status w))
      (buffer-set-document! b (world-status w)))))
