#lang racket

;;; core-rebuild/editor/render.rkt —— 渲染：panel display list → screen（全量 + 分层脏区增量）
;;;
;;;   panel = (view rect borders deep face)
;;;   布局层：panels → layout（内容 rect + 边框 run），只依赖面板几何
;;;   内容层：view → 文本屏（project + vrows）；overlay（光标/选区）每帧重算
;;;   合成  ：content panes ++ border panes → 逐行合成（按 deep 遮挡）
;;;   差量  ：screen-patch(old, new) → pieces
;;;
;;; 增量入口 render-display-patch 吃宿主持有的缓存（#f = 冷启动全量）：
;;;   · 整帧无变化        → 直接空差量（same-frame?）
;;;   · 布局/尺寸没变      → 只重合成「文本变化行」，其余行复用旧屏；只 patch 变化行
;;;   · 布局变 / 冷启动    → 全量
;;; 缓存是值、宿主持有、core 无状态。
;;;
;;; 失效键：内容层 = (document-revision, viewport)。

(require "state.rkt" "query.rkt"
         "../view/render.rkt" "../view/patch.rkt" "../view/compose.rkt"
         "../view/base/screen.rkt" "../view/base/rect.rkt" "../view/base/viewport.rkt"
         "../view/panel.rkt" "../view/layout.rkt"
         "../text/document.rkt")

(provide
 panel-cursor-position            ; panel → 主光标绝对屏幕位置
 render-display                   ; panels focus w h → screen（全量）
 render-display-patch             ; panels focus w h cache → (values cache render selection)（增量）
 render-cache-screen)             ; render-cache → screen

;;; ---------- 缓存对象 ----------

;; 每 view 一条：键 = (doc-revision . viewport)；值 = (rows vrows gutter) 文本层；sels = 上帧 overlay
(struct content-entry (key data sels) #:transparent)
;; 不透明旧帧：布局层 + 内容层 + 合成屏。
(struct render-cache (w h panels layout content screen) #:transparent)

;;; ---------- 内容层 ----------

(define (same-content-key? a b)
  (and (eq? (car a) (car b))        ; document-revision token：eq?
       (equal? (cdr a) (cdr b))))   ; viewport：字段比

;; 两版文本行向量 → 变化行下标（old=#f → 全部）。
(define (rows-diff old new)
  (if (not old)
      (for/list ([i (in-range (vector-length new))]) i)
      (let ([n (min (vector-length old) (vector-length new))])
        (append
         (for/list ([i (in-range n)] #:unless (equal? (vector-ref old i) (vector-ref new i))) i)
         (for/list ([i (in-range n (vector-length new))]) i)))))

;; view → (values 内容 screen 变化行下标)。文本层命中复用，overlay 每帧按 selections 装。
(define (content-screen v focused? old-content new-content)
  (define vp (view-viewport v))
  (define bd (view-document v))
  (define key (cons (document-revision bd) vp))
  (define cached (hash-ref old-content v #f))
  (define hit? (and cached (same-content-key? (content-entry-key cached) key)))
  (define data
    (if hit?
        (content-entry-data cached)
        (let-values ([(rows vrows gutter) (render-text bd vp)])
          (list rows vrows gutter))))
  (define changed
    (if hit? '() (rows-diff (and cached (car (content-entry-data cached))) (car data))))
  (define sels (and focused? (view-selections v)))
  (hash-set! new-content v (content-entry key data sels))
  (define rows (car data)) (define vrows (cadr data)) (define gutter (caddr data))
  (values (render-assemble bd vp rows vrows gutter sels) changed))

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

;; layout ⊕ focus ⊕ 内容缓存 → (values panes 文本变化屏幕行)。
(define (scene-panes+changed lay focs old-content new-content)
  (define changed '())
  (define content-panes
    (for/list ([pl (in-list (layout-placements lay))])
      (match-define (list v c deep) pl)
      (define cw (rect-w c)) (define ch (rect-h c))
      (define-values (scr chg) (content-screen v (memq v focs) old-content new-content))
      (when (pair? chg)
        (set! changed (append (for/list ([i (in-list chg)]) (+ (rect-y c) i)) changed)))
      (and (> cw 0) (> ch 0) (pane (rect-y c) (rect-x c) scr deep))))
  (define border-panes
    (for/list ([b (in-list (layout-border-runs lay))])
      (match-define (list row col text face deep) b)
      (pane row col (screen (string-length text) 1 (vector (list (run 0 text face))) '() '()) deep)))
  (values (append content-panes border-panes) changed))

;; overlay 按行分组（cursor/region 都在某一行内）。
(define (overlay-by-row cursors regions)
  (define h (make-hash))
  (for ([c (in-list cursors)]) (hash-update! h (cursor-row c) (λ (l) (cons c l)) '()))
  (for ([g (in-list regions)]) (hash-update! h (region-row g) (λ (l) (cons g l)) '()))
  h)

;; 旧屏 overlay 与新 overlay 不同的行。
(define (overlay-diff-rows old-screen new-cursors new-regions)
  (define a (if old-screen
                (overlay-by-row (screen-cursors old-screen) (screen-regions old-screen))
                (make-hash)))
  (define b (overlay-by-row new-cursors new-regions))
  (for/list ([r (in-list (remove-duplicates (append (hash-keys a) (hash-keys b))))]
             #:unless (equal? (hash-ref a r '()) (hash-ref b r '())))
    r))

;; 整帧无变化？布局 / 尺寸 / 每 view 内容键 / 每 view overlay selections 全同。
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

;;; ---------- 全量 ----------

(define (patch-full panels focus total-w total-h cache)
  (define lay (panels->layout panels))
  ;; 布局变也要复用内容层（内容键与布局无关）
  (define old-content (if (render-cache? cache) (render-cache-content cache) (make-hasheq)))
  (define content (make-hasheq))
  (define-values (panes _)
    (scene-panes+changed lay (focus-views focus) old-content content))
  (define new (panes->screen total-w total-h panes))
  (define old (and (render-cache? cache) (render-cache-screen cache)))
  (define-values (render selection) (screen-patch old new))
  (values (render-cache total-w total-h panels lay content new) render selection))

;;; ---------- 脏区 ----------

(define (patch-dirty panels focus total-w total-h cache)
  (define lay (render-cache-layout cache))
  (define old-screen (render-cache-screen cache))
  (define new-content (make-hasheq))
  (define-values (panes text-changed-raw)
    (scene-panes+changed lay (focus-views focus) (render-cache-content cache) new-content))
  ;; 文本变化行（裁到屏内）
  (define text-changed
    (remove-duplicates (filter (λ (r) (and (>= r 0) (< r total-h))) text-changed-raw)))
  (cond
    ;; 变化行多（滚动等）→ 整体合成（owner 只建一次）比逐行便宜
    [(> (length text-changed) (quotient total-h 3))
     (define new (panes->screen total-w total-h panes))
     (define-values (render selection) (screen-patch old-screen new))
     (values (render-cache total-w total-h panels lay new-content new) render selection)]
    [else
     (define new-rows (vector-copy (screen-rows old-screen)))
     (for ([r (in-list text-changed)])
       (vector-set! new-rows r (compose-row-of total-w panes r)))
     (define-values (new-cursors new-regions) (panes->overlay total-w total-h panes))
     (define overlay-changed (overlay-diff-rows old-screen new-cursors new-regions))
     (define patch-rows (remove-duplicates (append text-changed overlay-changed)))
     (define new (screen total-w total-h new-rows new-cursors new-regions))
     (define-values (render selection) (screen-patch-rows old-screen new patch-rows))
     (values (render-cache total-w total-h panels lay new-content new) render selection)]))

;;; ---------- 入口 ----------

;; display list → screen。全量（无缓存）。
(define (render-display panels focus total-w total-h)
  (define lay (panels->layout panels))
  (define-values (panes _)
    (scene-panes+changed lay (focus-views focus) (make-hasheq) (make-hasheq)))
  (panes->screen total-w total-h panes))

;; 增量：旧缓存 + 新 panels → (新缓存, render pieces, selection pieces)。
(define (render-display-patch panels focus total-w total-h cache)
  (cond
    [(same-frame? cache panels focus total-w total-h)
     (values cache '() '())]
    [(and (render-cache? cache)
          (equal? panels (render-cache-panels cache))
          (= total-w (render-cache-w cache))
          (= total-h (render-cache-h cache)))
     (patch-dirty panels focus total-w total-h cache)]
    [else
     (patch-full panels focus total-w total-h cache)]))

(module+ test
  (require rackunit "ops.rkt" "layout.rkt" "../text/base/point.rkt")
  (define b (make-buffer "hi\nthere\n"))
  (define v (buffer-add-view! b))
  (define p  (make-panel v (rect 0 0 10 5) borders-all))
  (define ps (list p))
  (panels-sync! ps)

  (define (content-data c) (content-entry-data (hash-ref (render-cache-content c) v)))

  (define-values (c1 a1 b1) (render-display-patch ps v 12 6 #f))
  (define-values (c2 a2 b2) (render-display-patch ps v 12 6 c1))
  (check-true (eq? (render-cache-layout c1) (render-cache-layout c2)))
  (check-true (eq? (content-data c1) (content-data c2)))
  (check-equal? (length a2) 0)          ; 无变化 → 空差量
  (check-equal? (length b2) 0)

  (define p2 (make-panel v (rect 1 0 10 5) borders-all))
  (define-values (c3 a3 b3) (render-display-patch (list p2) v 12 6 c2))
  (check-false (eq? (render-cache-layout c2) (render-cache-layout c3)))

  ;; 内容变：layout 复用，内容重算，只 patch 变化行
  (void (buffer-edit! b v (op-type "X")))
  (define-values (c4 r4 b4) (render-display-patch (list p2) v 12 6 c3))
  (check-true (eq? (render-cache-layout c3) (render-cache-layout c4)))
  (check-false (eq? (content-data c3) (content-data c4)))
  (check-true (> (length r4) 0))

  ;; 只动光标：内容层复用（文本重渲跳过）；diff 只涉及 overlay 行
  (define p3 (make-panel v (rect 1 0 10 5) borders-all))
  (view-set-point! v (point 1 0))          ; 移到另一行（插入后光标在 (0 1)）
  (define-values (c5 r5 s5) (render-display-patch (list p3) v 12 6 c4))
  (check-true (eq? (content-data c4) (content-data c5)))
  (check-true (> (+ (length r5) (length s5)) 0))   ; 旧光标格回文本 + 新光标格

  ;; 脏区不改变画面：与全量一致
  (define full (render-display (list p3) v 12 6))
  (check-equal? (screen->string (render-cache-screen c5)) (screen->string full))
  (displayln "render.rkt: ok"))
