#lang racket

;;; app/ops.rkt —— 操作「根对象」的原语层（layout / focus / document）
;;;
;;; 命里不再手写 `(modify (λ (w) (struct-copy world w [layout …])))`。
;;; 所有原语都是**纯构造器**：只产出 intent，不改状态、不碰 core、不新增状态。
;;;
;;; 约定：所有原语返回 `(listof intent)`（正是命令的返回类型），于是：
;;;   单操作命令  (λ (ctx) (hide-pane 'tree))
;;;   多操作命令  (λ (ctx) (append (hide-pane 'tree) (focus! ref)))
;;;
;;; 三类根：
;;;   layout   tree→tree / floats→floats 的纯变换，包成“改 world 根字段”的 intent
;;;   focus    改 world.focus（稳定 panel-ref）
;;;   document 编辑 intent 的命名封装（避免上层重复 op-* / invoke）
;;;
;;; 高级/任意布局改动直接用 `layout-op` 传一个 tree→tree 函数。

(require "../layout/main.rkt"
         "../../core/editor.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "intent.rkt")

(provide
 ;; layout
 layout-op mount-view
 show-pane hide-pane toggle-pane close-pane
 split-pane move-pane resize-seam
 ;; floats
 floats-op add-float remove-float
 ;; focus
 focus! focus-move
 ;; document
 insert-text delete-backward delete-forward
 navigate undo redo)

;;; ════════════════════════ layout ════════════════════════

;; 通用：tree → tree 的纯变换，包成“改 world.layout”的 intent。
(define (layout-op f)
  (list (modify (λ (w) (struct-copy world w [layout (f (world-layout w))])))))

(define (mount-view leaf-id v) (layout-op (λ (t) (tree-set-view t leaf-id v))))
(define (show-pane id)         (layout-op (λ (t) (tree-show t id))))
(define (hide-pane id)         (layout-op (λ (t) (tree-hide t id))))
(define (toggle-pane id)
  (layout-op (λ (t) (if (tree-visible? t id) (tree-hide t id) (tree-show t id)))))
(define (close-pane id)        (layout-op (λ (t) (tree-close t id))))
(define (split-pane id axis new-id #:side [side 'after])
  (layout-op (λ (t) (tree-split t id axis new-id #:side side))))
(define (move-pane id target axis #:side [side 'after])
  (layout-op (λ (t) (tree-move t id target axis #:side side))))
(define (resize-seam cut delta)
  (layout-op (λ (t) (tree-resize-seam t cut delta))))

;;; ════════════════════════ floats ════════════════════════

(define (floats-op f)
  (list (modify (λ (w) (struct-copy world w [floats (f (world-floats w))])))))
(define (add-float fl)     (floats-op (λ (fs) (floats-add fs fl))))
(define (remove-float key) (floats-op (λ (fs) (floats-remove fs key))))

;;; ════════════════════════ focus ════════════════════════

;; 切到指定 panel-ref（会清 pending）。
(define (focus! ref)
  (list (modify (λ (w) (world-focus-on w ref)))))

;; 面板间方向移动焦点：ctx.ref → 当帧 panel → panel-neighbor → 邻居 ref → focus!。
;; 返回 (listof intent)（无邻居 → '()）。
(define (focus-move ctx dir)
  (define w (ctx-world ctx))
  (define ps (world-panels w))
  (define refs (world-panel-refs w))
  (define from (for/first ([p (in-list ps)] [rf (in-list refs)]
                           #:when (equal? rf (ctx-ref ctx))) p))
  (cond
    [(not from) '()]
    [else
     (define nbr (panel-neighbor ps from dir))
     (define nbr-ref (and nbr (for/first ([p (in-list ps)] [rf (in-list refs)]
                                          #:when (eq? p nbr)) rf)))
     (if nbr-ref (focus! nbr-ref) '())]))

;;; ════════════════════════ document（薄封装编辑原语） ════════════════════════

(define (insert-text v text) (list (edit v (op-type text))))
(define (delete-backward v)  (list (edit v (op-backspace))))
(define (delete-forward v)   (list (edit v (op-delete))))
(define (navigate v op)      (list (invoke (λ () (op v)))))
(define (undo v)             (list (invoke (λ () (buffer-undo! (view-buffer v))))))
(define (redo v)             (list (invoke (λ () (buffer-redo! (view-buffer v))))))
