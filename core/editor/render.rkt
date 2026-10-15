#lang racket

;;; core/editor/render.rkt —— 渲染：panel display list → screen（全量 + 分层脏区增量）
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
 ;; ---------- 定位（单焦点模型）----------
 ;; core 的**绘制**支持多焦点（focus 可以是 (listof view)，每个焦点 view 各画光标/选区）；
 ;; 但下面这些「取焦点光标位置」的 API 按**单焦点**假定：只有一个焦点 view，
 ;; 合成屏里最多一个主光标。多焦点下要按 panel 取位置，用 panel-cursor-position(/visible)。
 panel-cursor-position            ; panel → 主光标绝对屏幕位置（几何，不看遮挡/越界）
 panel-cursor-position/visible    ; screen panel → 可见位置（几何 ∩ 已画光标）
 screen-primary-cursor            ; screen → 主光标 cursor | #f

 ;; ---------- 渲染 ----------
 render-display                   ; panels focus w h → screen（全量）
 render-display-patch             ; panels focus w h cache → (values cache render selection)（增量）
 (struct-out render-cache)        ; render-cache → screen / layout / content（后两者供外部测试复用检查）
 content-entry-data)              ; 内容层缓存 data（外部测试 / 诊断）

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

;; panel 的 view 主光标 → 屏幕绝对坐标（**纯几何**：内容区原点 + view 内光标坐标）。
;;
;; 不看遮挡、不裁边界：被高 deep 浮窗盖住、或 panel 部分在屏外，它照样返回坐标。
;; 要「实际画出来的位置」用 panel-cursor-position/visible。
;; 单焦点模型：宿主传进来的 focus 就是这块 panel 的 view。
(define (panel-cursor-position p)
  (define v (panel-view p))
  (if (not v)                                   ; 空面板：没有光标
      (values #f #f)
      (let ([c (panel-content p)])
        (define-values (r col) (view-cursor-screen-position v))
        (if r (values (+ (rect-y c) r) (+ (rect-x c) col))
            (values #f #f)))))

;; panel 的 view 光标在屏幕上的**可见**位置 = 几何位置 ∩ 这一帧真画出来的光标。
;; 合成（compose-overlay）已经把遮挡 / 越界裁掉，所以 screen-cursors 里在 = 可见。
;;
;; 注意：“可见”隐含“有 overlay”：只有**焦点** view 才会在 screen 里画 cursor，
;; 所以未焦点的 panel 这里恒为 (values #f #f)。
;; 单焦点模型下，这就是「焦点光标位置」，且已不含遮挡。
;;   screen panel → (values row col) | (values #f #f)
(define (panel-cursor-position/visible screen p)
  (define-values (r c) (panel-cursor-position p))
  (if (and r
           (for/or ([cu (in-list (screen-cursors screen))])
             (and (= (cursor-row cu) r) (= (cursor-column cu) c))))
      (values r c)
      (values #f #f)))

;; 合成屏上的主光标（焦点 view 的主选区光标）；被浮窗盖住 / 越界则不在表里。
;; 单焦点模型：返回的就是「焦点光标」。多焦点会有多个主光标，这个只取第一个，
;; 要按 view/panel 取用 panel-cursor-position(/visible)。
;;   screen → cursor | #f
(define (screen-primary-cursor screen)
  (for/first ([cu (in-list (screen-cursors screen))] #:when (cursor-primary? cu)) cu))

;; layout ⊕ focus ⊕ 内容缓存 → (values panes 文本变化屏幕行)。
(define (scene-panes+changed lay focs old-content new-content)
  (define changed '())
  (define content-panes
    (for/list ([pl (in-list (layout-placements lay))])
      (match-define (list v c deep) pl)
      (define cw (rect-w c)) (define ch (rect-h c))
      (and v                                        ; 空面板（view = #f）：没有内容 pane
           (let-values ([(scr chg) (content-screen v (memq v focs) old-content new-content)])
             (when (pair? chg)
               (set! changed (append (for/list ([i (in-list chg)]) (+ (rect-y c) i)) changed)))
             (and (> cw 0) (> ch 0) (pane (rect-y c) (rect-x c) scr deep))))))
  (define border-panes
    (for/list ([b (in-list (layout-border-runs lay))])
      (match-define (list row col text face deep) b)
      (pane row col (screen (string-length text) 1 (vector (list (run 0 text face))) '() '()) deep)))
  (values (filter values (append content-panes border-panes)) changed))

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
           (or (not v)                              ; 空面板：没有内容要比较
               (let ([e (hash-ref old-content v #f)])
                 (and e
                      (same-content-key? (content-entry-key e)
                                         (cons (document-revision (view-document v)) (view-viewport v)))
                      (equal? (and (memq v focs) (view-selections v))
                              (content-entry-sels e)))))))))

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
