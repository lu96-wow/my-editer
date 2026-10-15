#lang racket

;;; core-rebuild/editor/render.rkt —— 渲染：panel display list → screen（全量 + 分层增量缓存）
;;;
;;;   panel = (view rect borders deep face)     宿主直接给 panel 值
;;;   布局层：panels → layout（内容 rect + 边框 run），只依赖面板几何
;;;   内容层：view → 文本屏（project + vrows）；overlay（光标/选区）每帧重算
;;;   合成  ：content panes ++ border panes → panes->screen（按 deep）
;;;   差量  ：screen-patch(old, new) → pieces
;;;
;;; 增量入口 render-display-patch 吃一个**宿主持有的缓存对象**（#f = 冷启动全量）：
;;;   render-cache 里存上一帧的 panels + layout + 每 view 的文本层 + 合成屏；
;;;   · panels 没变       → layout 复用（边框层跳过）
;;;   · (doc revision, viewport) 没变 → 该 view 文本层复用（project 跳过）
;;;   overlay 依赖 selections，每帧重算；屏照旧 screen-patch 出格级差量。
;;; 缓存是**值**：core 不存任何跨帧状态，函数保持纯（cache 进 → cache' 出）。
;;;
;;; 失效键：内容层 = (document-revision, viewport)。
;;;   document 文本编辑会换 document；face/readonly 是 box 就地改，所以靠 revision
;;;   token（任何影响渲染的写路径都会换新 token，见 text/document.rkt）。
;;;   viewport 含 top-line / left-column / mode / width / height —— 滚动 / 横滚 /
;;;   改尺寸都会换。

(require "state.rkt" "query.rkt"
         "../view/render.rkt" "../view/patch.rkt" "../view/compose.rkt"
         "../view/base/screen.rkt" "../view/base/rect.rkt" "../view/base/viewport.rkt"
         "../view/panel.rkt" "../view/layout.rkt"
         "../text/document.rkt")

(provide
 panel-cursor-position            ; panel → 主光标绝对屏幕位置 (values row col) | (values #f #f)
 render-display                   ; panels focus w h → screen（全量）
 render-display-patch             ; panels focus w h cache → (values cache render selection)（增量）
 render-cache-screen)             ; render-cache → screen（上一帧合成屏）

;;; ---------- 缓存对象（宿主持有，core 无状态）----------

;; 每 view 一条：键 = (doc-revision . viewport)；值 = (rows vrows gutter)（文本层）；sels = 上帧的 overlay
(struct content-entry (key data sels) #:transparent)

;; 不透明旧帧：布局层 + 内容层 + 合成屏。
;; 注：panel 现在是**值**，layout 直接 captured 列表 + equal? 判等；
;;     内容层按 view 的 eq? 身份存（make-hasheq）。
(struct render-cache (w h panels layout content screen) #:transparent)

;;; ---------- 内容层 ----------

(define (same-content-key? a b)
  (and (eq? (car a) (car b))        ; document-revision token：eq?
       (equal? (cdr a) (cdr b))))   ; viewport：字段比

;; view → 内容 pane 的 screen。文本层命中复用，overlay 每帧按 selections 重算。
(define (content-screen v focused? old-content new-content)
  (define vp (view-viewport v))
  (define bd (view-document v))
  (define key (cons (document-revision bd) vp))
  (define cached (hash-ref old-content v #f))
  (define data
    (if (and cached (same-content-key? (content-entry-key cached) key))
        (content-entry-data cached)
        (let-values ([(rows vrows gutter) (render-text bd vp)])
          (list rows vrows gutter))))
  (define sels (and focused? (view-selections v)))
  (hash-set! new-content v (content-entry key data sels))
  (match-define (list rows vrows gutter) data)
  (render-assemble bd vp rows vrows gutter sels))

;;; ---------- 渲染 ----------

(define (focus-views focus)
  (cond [(not focus) '()]
        [(list? focus) focus]
        [else (list focus)]))

(define (panel-cursor-position p)
  (define v (panel-view p))
  (define c (panel-content p))
  (define-values (r col) (view-cursor-screen-position v))
  (if r (values (+ (rect-y c) r) (+ (rect-x c) col))
        (values #f #f)))

;; layout ⊕ focus ⊕ 内容缓存 → panes（内容 pane + 边框 pane），同时填 new-content。
(define (scene-panes lay focs old-content new-content)
  (append
   (for/list ([pl (in-list (layout-placements lay))])
     (match-define (list v c deep) pl)
     (define cw (rect-w c)) (define ch (rect-h c))
     (and (> cw 0) (> ch 0)
          (pane (rect-y c) (rect-x c)
                (content-screen v (memq v focs) old-content new-content)
                deep)))
   (for/list ([b (in-list (layout-border-runs lay))])
     (match-define (list row col text face deep) b)
     (pane row col
           (screen (string-length text) 1
                   (vector (list (run 0 text face))) '() '())
           deep))))

(define (compose-screen lay focus w h old-content new-content)
  (composition-screen
   (panes->composition w h (scene-panes lay (focus-views focus) old-content new-content))))

;; display list → screen。全量（无缓存）。
(define (render-display panels focus total-w total-h)
  (compose-screen (panels->layout panels) focus total-w total-h (make-hasheq) (make-hasheq)))

;; 整帧无变化？布局 / 尺寸 / 每 view 的内容键 / 每 view 的 overlay selections 全同。
;; 是 → 新屏与旧屏逐格相同，可以跳过合成 + screen-patch（返回旧缓存 + 空差量）。
(define (same-frame? cache panels focus w h)
  (and (render-cache? cache)
       (= w (render-cache-w cache))
       (= h (render-cache-h cache))
       (equal? panels (render-cache-panels cache))
       (let ([old-content (render-cache-content cache)]
             [focs (focus-views focus)])
         (for/and ([pl (in-list (layout-placements (render-cache-layout cache)))])
           (match-define (list v c deep) pl)
           (define e (hash-ref old-content v #f))
           (and e
                (same-content-key? (content-entry-key e)
                                   (cons (document-revision (view-document v)) (view-viewport v)))
                (equal? (and (memq v focs) (view-selections v))
                        (content-entry-sels e)))))))

;; 增量：旧缓存 + 新 panels → (新缓存, render pieces, selection pieces)。
;; cache = #f → 冷启动（全量）。整帧无变化 → 直接空差量。
(define (render-display-patch panels focus total-w total-h cache)
  (cond
    [(same-frame? cache panels focus total-w total-h)
     (values cache '() '())]
    [else
     (define lay
       (if (and (render-cache? cache)
                (equal? panels (render-cache-panels cache)))
           (render-cache-layout cache)          ; 布局没变 → 复用（边框层跳过）
           (panels->layout panels)))
     (define old-content (if (render-cache? cache) (render-cache-content cache) (make-hasheq)))
     (define new-content (make-hasheq))
     (define new (compose-screen lay focus total-w total-h old-content new-content))
     (define old (and (render-cache? cache) (render-cache-screen cache)))
     (define-values (render selection) (screen-patch old new))
     (values (render-cache total-w total-h panels lay new-content new) render selection)]))

(module+ test
  (require rackunit "ops.rkt" "layout.rkt" "../text/base/point.rkt")
  (define b (make-buffer "hi\nthere\n"))
  (define v (buffer-add-view! b))
  (define p  (make-panel v (rect 0 0 10 5) borders-all))
  (define ps (list p))
  (panels-sync! ps)                     ; view 尺寸 = 内容区（否则 1 宽会随光标横滚）

  (define (content-data c) (content-entry-data (hash-ref (render-cache-content c) v)))

  ;; 冷启动 → 有 layout / 内容
  (define-values (c1 a1 b1) (render-display-patch ps v 12 6 #f))
  ;; 同样 panels + 同样内容 → layout 与内容都复用；整帧无变化 → 空差量（快路径）
  (define-values (c2 a2 b2) (render-display-patch ps v 12 6 c1))
  (check-true (eq? (render-cache-layout c1) (render-cache-layout c2)))
  (check-true (eq? (content-data c1) (content-data c2)))
  (check-equal? (length a2) 0)
  (check-equal? (length b2) 0)

  ;; rect 变了（新 panel 值）→ layout 重算
  (define p2 (make-panel v (rect 1 0 10 5) borders-all))
  (define-values (c3 a3 b3) (render-display-patch (list p2) v 12 6 c2))
  (check-false (eq? (render-cache-layout c2) (render-cache-layout c3)))

  ;; 内容变了但 panels 不变 → layout 仍复用，内容层重算，diff 出片
  (void (buffer-edit! b v (op-type "X")))
  (define-values (c4 r4 b4) (render-display-patch (list p2) v 12 6 c3))
  (check-true (eq? (render-cache-layout c3) (render-cache-layout c4)))
  (check-false (eq? (content-data c3) (content-data c4)))
  (check-true (> (length r4) 0))

  ;; 只动光标（selection）→ 内容层仍复用（overlay 单独重算）
  (define p3 (make-panel v (rect 1 0 10 5) borders-all))
  (view-set-point! v (point 0 1))
  (define-values (c5 r5 s5) (render-display-patch (list p3) v 12 6 c4))
  (check-true (eq? (content-data c4) (content-data c5)))
  (displayln "render.rkt: ok"))
