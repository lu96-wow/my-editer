#lang racket

;;; edit4/content/placing.rkt —— 打开文件时的放置选择（多窗口）
;;;
;;; 规则（本项目的约束）：
;;;   · 没有编辑器窗   → 新开一个；
;;;   · 恰好 1 个      → 直接放；
;;;   · 其余（≥2 个）  → 进入 placing，由用户选目标窗。
;;;
;;; placing 状态存在 content 里（与 prompt 同构）：vid = 待放置视图，prev-focus = 进入前焦点。
;;; 视图在确认前不入任何窗口绑定；取消只清 placing + 回焦（文档保持已打开、未显示）。

(provide placing-commands place-vid! reveal-or-place! reveal-or-place-doc!)

(require racket/list
         "../core/world.rkt" "../core/command.rkt" "../core/event.rkt"
         "../layout.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt")

;; 编辑器窗口（vid 空 / 非面板）。
(define (editor-windows w)
  (content-editor-windows (world-content w) (world-layout w)))

(define (placing-of w)
  (and (world-content w) (content-placing (world-content w))))

;;; ---------- 放置 ----------

;; 新开一个编辑器窗贴到 anchor 右边（anchor = 当前焦点 / 第一个窗）。
(define (new-editor-window w vid)
  (define c (world-content w))
  (define lay (world-layout w))
  (define nid (fresh-id lay))
  (define anchor (or (world-focus w) (for/first ([id (in-list (visible-ids lay))]) id)))
  (define nleaf (leaf nid (cons 2 2)))
  (define nlay (if anchor
                   (insert-adjacent lay anchor 'right (size 40 #f) nleaf)
                   (insert-side lay 'right (size 40 #f) nleaf)))
  (world-set-focus (world-set-content (world-set-layout w nlay) (content-bind c nid vid)) nid))

(define (place-vid! w vid)
  (define c (world-content w))
  (define wins (editor-windows w))
  (cond
    [(null? wins) (new-editor-window w vid)]
    [(null? (cdr wins))
     ;; 单个编辑器窗（空 / 已有文档都算）→ 直接放
     (define id (car wins))
     (world-set-focus (world-set-content w (content-bind c id vid)) id)]
    [else
     (define cur (world-focus w))
     (define target (if (and cur (memv cur wins)) cur (car wins)))
     (world-set-content (world-set-focus w target)
                        (content-set-placing (world-content w) (placing vid cur)))]))

;; 视图已显示 → 聚焦那个窗口；否则放置。
(define (reveal-or-place! w vid)
  (define id (window-of-vid w vid))
  (cond
    [id (world-set-focus w id)]
    [else (place-vid! w vid)]))

;; 文档：复用其第一个视图（已显示则聚焦），否则新建视图再放置。
(define (reveal-or-place-doc! w did)
  (define c (world-content w))
  (define vids (document-view-list (content-ed c) did))
  (cond
    [(pair? vids) (reveal-or-place! w (car vids))]
    [else
     (define-values (c* vid) (content-add-view! c did 60 22))
     (reveal-or-place! (world-set-content w c*) vid)]))

;;; ---------- 命令 ----------

(define (h-place-cycle ctx w args)
  (define d (car args))
  (cond
    [(not (placing-of w)) #f]
    [else
     (define wins (editor-windows w))
     (cond
       [(null? wins) #f]
       [else
        (define cur (world-focus w))
        (define i (or (for/first ([x (in-list wins)] [k (in-naturals)] #:when (eqv? x cur)) k) 0))
        (cons (world-set-focus w (list-ref wins (modulo (+ i d) (length wins)))) '())])]))

(define (h-place-confirm ctx w args)
  (define c (world-content w))
  (define p (content-placing c))
  (cond
    [(not p) #f]
    [else
     (define wins (editor-windows w))
     (define target (world-focus w))
     (define t (cond [(and target (memv target wins)) target]
                     [(pair? wins) (car wins)]
                     [else #f]))
     (cond
       [(not t) #f]
       [else
        (define w1 (world-set-content w (content-bind c t (placing-vid p))))
        (define w2 (world-set-content w1 (content-set-placing (world-content w1) #f)))
        (cons (world-set-focus w2 t) '())])]))

(define (h-place-cancel ctx w args)
  (define c (world-content w))
  (define p (content-placing c))
  (cond
    [(not p) #f]
    [else
     (define w1 (world-set-content w (content-set-placing c #f)))
     (define prev (placing-prev-focus p))
     (cons (world-set-focus w1 (if (and prev (has-id? w1 prev)) prev (world-focus w1))) '())]))

;; 鼠标点：命中平铺窗且是编辑器窗 → 切换目标焦点；
;; 其余（面板 / 浮窗 / 缝 / 空白）→ **消费但不改任何状态**（不碰文件树等面板的游标）。
(define (h-place-pick ctx w args)
  (cond
    [(not (placing-of w)) #f]
    [else
     (define fr (ctx-frame ctx))
     (cond
       [(not fr) (cons w '())]
       [else
        (define ev (ctx-event ctx))
        (define t (hit-frame fr (cursor-event-x ev) (cursor-event-y ev)))
        (define wid (and (pane-target? t) (pane-target-id t)))
        (define wins (editor-windows w))
        (cond
          [(and wid (memv wid wins)) (cons (world-set-focus w wid) '())]
          [else (cons w '())])])]))

(define placing-commands
  (make-command-registry
   (list (cons 'place-cycle h-place-cycle)
         (cons 'place-confirm h-place-confirm)
         (cons 'place-cancel h-place-cancel)
         (cons 'place-pick h-place-pick))))
