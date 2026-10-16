#lang racket

;;; app/panel-ref.rkt —— panel 的稳定身份 + 解析
;;;
;;; ④ 的核心：把「焦点 / 拖动 / ctx 的主体」从**每帧重算的 panel** 或
;;; **可被替换的 view 值**，统一提升成**稳定的 panel 身份**：
;;;
;;;   leaf  → leaf id
;;;   float → float key
;;;
;;; 用 kind 区分（leaf id 与 float key 可能撞名）。view / panel 都由 ref 按
;;; **当前** tree / floats 解析得到 —— 所以 view 被 tree-set-view 替换、
;;; 布局被重排，ref 都不悬空。
;;;
;;; 与 world 解耦：本模块只吃 layout + floats + area，不 require world。

(require "../layout/main.rkt"
         "../../core/editor.rkt")

(provide (struct-out panel-ref)
         leaf-ref float-ref
         ref->view ref->panel
         panels->refs placements->refs panel->ref)

(struct panel-ref (kind id) #:transparent)
;; kind : 'leaf | 'float
;; id   : any/c（leaf id | float key）

(define (leaf-ref id)   (panel-ref 'leaf id))
(define (float-ref key) (panel-ref 'float key))

;;; ---------- ref → 当帧 view / panel ----------

;; 不在布局里 / 隐藏 / 不存在的 float → #f。
(define (ref->view layout floats ref)
  (case (panel-ref-kind ref)
    [(leaf)  (define l (tree-find layout (panel-ref-id ref)))
             (and l (leaf-view l))]
    [(float) (define f (floats-ref floats (panel-ref-id ref)))
             (and f (float-view f))]
    [else #f]))

;; 坐标换算用（隐藏 leaf 不在 tree->panels → #f）。
(define (ref->panel layout floats area ref)
  (case (panel-ref-kind ref)
    [(leaf)  (hash-ref (tree-panel-map layout area) (panel-ref-id ref) #f)]
    [(float) (for/first ([x (in-list floats)] [p (in-list (floats->panels floats))]
                         #:when (eq? (float-key x) (panel-ref-id ref))) p)]
    [else #f]))

;;; ---------- panels ↔ refs（同序）----------

;; 由一次 solve 的 placements + floats 生成与 panels 同序的 ref 列表。
(define (placements->refs placements floats)
  (append
   (for/list ([pl (in-list placements)]) (leaf-ref (car pl)))
   (for/list ([f (in-list floats)]) (float-ref (float-key f)))))

;; 与 (append (tree->panels …) (floats->panels …)) **严格同序**的 ref 列表。
(define (panels->refs layout floats area)
  (placements->refs (tree->placements layout area) floats))

;; 命中 panel → ref。panel-at 返回的是列表里的同一个对象（eq?），所以用 eq? 配对。
(define (panel->ref panels refs p)
  (and p (for/first ([p* (in-list panels)] [r (in-list refs)] #:when (eq? p p*)) r)))
