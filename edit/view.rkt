#lang racket

;;; edit/view.rkt —— 视图（纯函数）
;;;
;;; 视图 = id + did + window + selections + 放置 + 层深。
;;; **视图不揣 document**，只持 did；凡是要文本的操作都把 document 显式传进来
;;;（和 core 的 viewport-* 收 track 一样）。
;;;
;;; 纯：所有函数都是 value -> value（或派生值）；不 set-box!、不读全局。
;;;
;;; 坐标约定：
;;;     point   = (buffer 行, 行内字符列)
;;;     屏幕     = (row, col)，col 是显示列（含行号栏偏移）
;;;     层深     = 大者在上；同深度按合成列表顺序，靠后在上

(require "../core/text/base/point.rkt"
         "../core/text/base/change.rkt"
         "../core/text/base/selection.rkt"
         "../core/text/base/line.rkt"
         "../core/text/base/track.rkt"
         "../core/text/document.rkt"
         "../core/text/rebase.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/base/viewport.rkt"
         "../core/view/render.rkt"
         "../core/view/compose.rkt"
         "../core/view/patch.rkt")

;;; ---------- 值 ----------

;; 窗口：看哪儿。尺寸不在里面（尺寸 = view 的 w h）。
(struct window (top-line top-segment left-column mode line-numbers?) #:transparent)
;; top-line      : 顶部 buffer 行
;; top-segment   : wrap 下顶部行的第几个折行段（clip 忽略）
;; left-column   : clip 下水平起始显示列（wrap 忽略）
;; mode          : 'clip | 'wrap
;; line-numbers? : 是否显示行号栏

;; 视图：did + 窗口 + 选区 + 放置 + 层深。（document 由调用方按 did 取）
(struct view (id did window selections x y w h depth visible?) #:transparent)

;;; ---------- 层深（命名常量） ----------
;;; 只表达**视图之间**的叠放；视图**内部**的光标 / 选区由 core 的 overlay 处理。

(define layer-base 0)
(define layer-deco 100)
(define layer-overlay 200)

(provide
 (struct-out window)
 (struct-out view)
 layer-base layer-deco layer-overlay

 ;; 构造
 view-open

 ;; 放置 / 层
 view-set-rect view-move view-resize view-set-depth view-show

 ;; 窗口
 view-set-mode view-set-line-numbers view-scroll view-set-anchor view-anchor view-ensure

 ;; 选区 / 导航
 view-set-point view-set-selections view-select-all view-nav view-clamp view-rebase

 ;; 投影 / 读
 view-render view-point->screen view-screen->point

 ;; 合成
 view-pane compose compose-patch)

;;; ---------- 构造 ----------

(define (view-open id did x y w h
                   #:mode [mode 'clip]
                   #:line-numbers? [line-numbers? #f]
                   #:depth [depth layer-base]
                   #:visible? [visible? #t]
                   #:selections [sels #f])
  (view id did
        (window 0 0 0 mode line-numbers?)
        (or sels (selections-one (caret (point 0 0))))
        x y w h depth visible?))

;;; ---------- 放置 / 层（纯 struct-copy） ----------

(define (view-move v x y)   (struct-copy view v [x x] [y y]))
(define (view-set-depth v d) (struct-copy view v [depth d]))
(define (view-show v on?)   (struct-copy view v [visible? on?]))

;; 改尺寸后保持左上锚点（wrap 段号 / clip 左列会随新宽重算）。
(define (view-resize v doc w h)
  (cond
    [(and (= w (view-w v)) (= h (view-h v))) v]
    [else
     (define-values (line dc) (view-anchor v doc))
     (view-set-anchor (struct-copy view v [w w] [h h]) doc line dc)]))

(define (view-set-rect v doc x y w h) (view-move (view-resize v doc w h) x y))

;;; ---------- 窗口 ↔ core viewport 桥（内部） ----------

(define (view->viewport v)
  (define w (view-window v))
  (viewport (window-top-line w) (window-top-segment w) (window-left-column w)
            (view-w v) (view-h v) (window-mode w) (window-line-numbers? w)))

(define (viewport->window vp)
  (window (viewport-top-line vp) (viewport-top-segment vp) (viewport-left-column vp)
          (viewport-mode vp) (viewport-line-numbers? vp)))

(define (view-with-window v w) (struct-copy view v [window w]))

;;; ---------- 窗口变换（要 doc） ----------

(define (view-set-mode v doc m)
  (cond
    [(eq? m (window-mode (view-window v))) v]
    [else
     (define-values (line dc) (view-anchor v doc))
     (view-set-anchor (view-with-window v (struct-copy window (view-window v) [mode m]))
                      doc line dc)]))

(define (view-set-line-numbers v doc on?)
  (cond
    [(eq? on? (window-line-numbers? (view-window v))) v]
    [else
     (define-values (line dc) (view-anchor v doc))
     (view-set-anchor (view-with-window v (struct-copy window (view-window v) [line-numbers? on?]))
                      doc line dc)]))

(define (view-scroll v doc n)
  (view-with-window v (viewport->window (viewport-scroll (document-text doc) (view->viewport v) n))))

(define (view-set-anchor v doc line dc)
  (view-with-window v
    (viewport->window (viewport-set-anchor (document-text doc) (view->viewport v) line dc))))

(define (view-anchor v doc)
  (viewport-anchor (document-text doc) (view->viewport v)))

(define (view-ensure v doc p)
  (view-with-window v
    (viewport->window (viewport-ensure (document-text doc) (view->viewport v) p))))

;;; ---------- 选区 / 导航 ----------

(define (view-set-point v p)
  (struct-copy view v [selections (selections-one (caret p))]))

(define (view-set-selections v sels)
  (struct-copy view v [selections sels]))

(define (view-select-all v doc)
  (define t (document-text doc))
  (define last (sub1 (track-length t)))
  (struct-copy view v
    [selections (selections-one (selection (point 0 0)
                                           (point last (track-line-length t last))))]))

;; dir : 'left 'right 'up 'down 'home 'end
;; extend? : #t = 只动 head（扩选）；#f = 收拢成光标（go）
;; 移动后把新主光标 ensure 进视口。
(define (view-nav v doc dir extend?)
  (define t (document-text doc))
  (define vp (view->viewport v))
  (define f
    (case dir
      [(left)  (lambda (p) (point-left t p))]
      [(right) (lambda (p) (point-right t p))]
      [(home)  (lambda (p) (point-home t p))]
      [(end)   (lambda (p) (point-end t p))]
      [(up)    (lambda (p) (point-up t vp p))]
      [(down)  (lambda (p) (point-down t vp p))]
      [else (error 'view-nav "未知方向: ~a（'left 'right 'up 'down 'home 'end）" dir)]))
  (define sels* ((if extend? selections-extend selections-go) (view-selections v) f))
  (view-ensure (struct-copy view v [selections sels*]) doc
               (selection-head (selections-primary sels*))))

(define (view-clamp v doc)
  (define t (document-text doc))
  (struct-copy view v
    [selections (selections-clamp (view-selections v) (track-length t)
                                  (curry track-line-length t))]))

(define (view-rebase v changes)
  (struct-copy view v [selections (selections-rebase changes (view-selections v))]))

;;; ---------- 投影 / 读（要 doc） ----------

(define (view-render v doc)
  (render doc (view->viewport v) (view-selections v)))

(define (view-point->screen v doc p)
  (viewport-point->screen-position (document-text doc) (view->viewport v) p))

(define (view-screen->point v doc row col)
  (viewport-screen-position->point (document-text doc) (view->viewport v) row col))

;;; ---------- 合成（doc-of : did -> document） ----------

(define (view-pane v doc)
  (pane (view-id v) (view-y v) (view-x v) (view-render v doc) (view-depth v)))

(define (compose views doc-of active total-w total-h)
  (panes->screen total-w total-h
                 (for/list ([v (in-list views)] #:when (view-visible? v))
                   (view-pane v (doc-of (view-did v))))
                 active))

;; 增量：旧帧 + 本帧 -> (values 新帧 render selection)
(define (compose-patch old views doc-of active total-w total-h)
  (define new (compose views doc-of active total-w total-h))
  (define-values (render* selection) (screen-patch old new))
  (values new render* selection))
