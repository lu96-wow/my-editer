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
;;;
;;; 也管「关编辑器窗」（C-d）：最后一个编辑器窗是**常驻的空占位**，只解绑不删叶子，
;;; 主区弹性仍在，dock（树 / 状态栏）尺寸不漂。

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

;; 主区锚点：树里第一个 dock 叶子；优先 anchor 'main 的（它们当初就贴着编辑器）。
;; main 没有独立节点，主区由这些 dock 隐含；没有 main dock 时退到 root dock，
;; 主区就在它的反侧。id -> region 的对应一次性建表。
(define (dock-anchor-leaf c lay)
  (define by-leaf
    (for/hash ([r (in-hash-values (content-regions c))] #:when (region-leaf r))
      (values (region-leaf r) r)))
  (define-values (main dock)
    (for/fold ([main #f] [dock #f]) ([id (in-list (ids lay))])
      (define r (hash-ref by-leaf id #f))
      (cond
        [(not r) (values main dock)]
        [(eq? (region-anchor r) 'main) (values (or main id) (or dock id))]
        [else (values main (or dock id))])))
  (or main dock))

(define (dock-side c id)
  (for/first ([r (in-hash-values (content-regions c))]
              #:when (eqv? (region-leaf r) id))
    (region-side r)))

;; dock 在底 → 编辑器插其上；在顶 → 插其下；左右同理。
(define (opposite side)
  (case side [(top) 'bottom] [(bottom) 'top] [(left) 'right] [(right) 'left] [else 'right]))

;; 新开一个编辑器窗：放进「主区」——贴到 dock 的反侧。
;; 只认 dock 的位置，不认当前焦点（焦点可能是侧栏/状态栏等面板，
;; 贴上去会把编辑器嵌进 dock 所在的横/纵带里，见 11-docks.md 的锚点语义）。
(define (new-editor-window w vid)
  (define c (world-content w))
  (define lay (world-layout w))
  (define nid (fresh-id lay))
  (define nleaf (leaf nid (cons 2 2)))
  (define anchor (dock-anchor-leaf c lay))
  (define nlay
    (cond
      [anchor (insert-adjacent lay anchor (opposite (dock-side c anchor)) (size 40 #f) nleaf)]
      [else (insert-side lay 'right (size 40 #f) nleaf)]))
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

;; 两个编辑器窗互换视图：几何/尺寸/焦点都不动，只换 vid 绑定。
;; 参数 (swap-view A B)：A/B = 窗口 id、'focus、或 'next / 'prev
;; （相对焦点在编辑器窗序列里的下一个/上一个；焦点不在编辑器窗时取第一个/最后一个）。
(define (swap-target wins focus x)
  (cond
    [(eq? x 'focus) focus]
    [(memq x '(next prev))
     (cond
       [(null? wins) #f]
       [else
        (define m (for/first ([id (in-list wins)] [k (in-naturals)] #:when (eqv? id focus)) k))
        (define i (or m (if (eq? x 'next) -1 0)))
        (define d (if (eq? x 'next) 1 -1))
        (list-ref wins (modulo (+ i d) (length wins)))])]
    [else x]))

(define (h-swap-view ctx w args)
  (define c (world-content w))
  (define wins (editor-windows w))
  (define focus (world-focus w))
  (define a (swap-target wins focus (car args)))
  (define b (swap-target wins focus (cadr args)))
  (cond
    [(not (and c a b (memv a wins) (memv b wins) (not (eqv? a b)))) #f]
    [else (cons (world-set-content w (content-swap-vids c a b)) '())]))

;; C-d：关闭焦点编辑器窗（**只对编辑器窗生效**，面板/浮窗一律不动）。
;;   · 只剩一个编辑器窗 → **保留叶子、只解绑** → 空编辑器占位（主区弹性不消失，
;;     树/状态栏尺寸不变；新开文件会直接放回这一格）；
;;   · 多个 → 删叶子 + 解绑，焦点回退到另一个编辑器窗。
;; 与 buffers 关视图（content-remove-vid 后叶子留空）同构。
;; 绑在 always 上（而非 editor scope）：空编辑器窗 vid = #f，editor scope 不成立，
;; 但空占位同样不该被删。
(define (h-close-window ctx w args)
  (define c (world-content w))
  (define id (world-focus w))
  (define lay (world-layout w))
  (cond
    [(not (and c id)) (cons w '())]
    [(content-placing c) (cons w '())]              ; 正在选放置目标：不关
    [else
     (define wins (editor-windows w))
     (cond
       [(not (memv id wins)) (cons w '())]          ; 面板 / 未知窗：消费但不改
       [(null? (cdr wins))                          ; 最后一个编辑器窗 → 空占位
        (cons (world-set-content w (content-unbind c id)) '())]
       [else
        (define nl (remove-leaf lay id))
        (define w1 (world-set-layout w nl))
        (define w2 (world-set-content w1 (content-unbind (world-content w1) id)))
        (define target (or (content-editor-window (world-content w2) nl)
                           (for/first ([x (in-list (ids nl))]) x)))
        (cons (world-set-focus w2 target) '())])]))

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
   (list (cons 'close-window h-close-window)
         (cons 'swap-view h-swap-view)
         (cons 'place-cycle h-place-cycle)
         (cons 'place-confirm h-place-confirm)
         (cons 'place-cancel h-place-cancel)
         (cons 'place-pick h-place-pick))))
