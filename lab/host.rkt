#lang racket

(require "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "layout.rkt")

;;; host.rkt —— 通用 editor 运行时（宿主）
;;;
;;; 管这些**通用**的东西，不认识任何具体组件：
;;;   editor       core 值（documents × views）
;;;   focus        当前 pane id（core 不管焦点，宿主自持）
;;;   layout       声明式布局（layout.rkt）→ rect 列表
;;;   size         rows / cols
;;;   last-screen  增量基线
;;;   comps        注册的组件：id → vid + sync + state
;;;
;;; 一帧（host-frame）：
;;;   跑每个组件的 sync（纯投影 ctx × state → document × state）
;;;   → 幂等写进该组件的 vid（editor-view-assign）
;;;   → layout 解析成 rects + 尺寸落地
;;;   → editor-render-layout（内容 + 组件一起合成）→ 装饰分隔带 → screen-patch(旧,新)
;;;
;;; **组件只读**：sync 拿到的 ctx 是只读契约（editor + 焦点信息 + 尺寸），
;;; 没有写口。写 editor / 渲染 / 增量全部由 host 一处负责。

(provide
 ;; ---------- 类型 ----------
 (struct-out ctx)
 (struct-out host)

 ;; ---------- 构造 / 注册 ----------
 host-open
 host-add-document
 host-adopt-view
 host-set-pane-state host-pane-state
 host-pane-vid
 host-remove-pane

 ;; ---------- 焦点 / 布局 / 尺寸 ----------
 host-set-focus host-set-focus-vid host-focused-vid
 host-set-layout
 host-resize

 ;; ---------- 查询 / 命中 ----------
 host-view-at

 ;; ---------- 帧 ----------
 host-frame)

;;; ---------- 类型 ----------

;; 注册在 host 上的一个组件（内部）。
(struct comp (id vid sync state) #:transparent #:constructor-name make-comp)
;; id    : pane-id（host 分配；layout / focus 用它）
;; vid   : core 视图 id（写口由 host 用）
;; sync  : (or/c #f (ctx × state → (values document state)))   #f = 纯内容视图，不自动投影
;; state : 组件自己的状态（host 不解释）

;; 组件投影时拿到的**只读**上下文。
(struct ctx (editor focus-id focus-vid self-id self-vid rows cols) #:transparent)
;; editor    : editor     只读（core 值）
;; focus-id  : pane-id    当前焦点 pane（可能 #f）
;; focus-vid : vid        当前焦点视图（可能 #f）—— 组件真正要读的
;; self-id   : pane-id    正在被投影的组件
;; self-vid  : vid        它自己的视图 id
;; rows/cols : nat        整屏尺寸

(struct host (editor focus-id layout rows cols last-screen comps next-id) #:transparent)

;;; ---------- 构造 / 注册 ----------

(define (host-open editor rows cols)
  (host editor #f #f rows cols #f '() 0))

(define (find-comp h id)
  (for/first ([p (in-list (host-comps h))] #:when (= id (comp-id p))) p))

;; 加一个「文档 + 视图」，注册为组件。→ (values host id)
(define (host-add-document h text width height [name "*pane*"]
                           #:sync [sync #f] #:state [state #f]
                           #:history? [history? #t]
                           #:mode [mode 'clip]
                           #:line-numbers? [ln #f])
  (define-values (ed _did vid)
    (editor-add-document-view (host-editor h) text width height name
                              #:history? history? #:mode mode #:line-numbers? ln))
  (define id (host-next-id h))
  (values (struct-copy host h
            [editor ed]
            [comps (append (host-comps h) (list (make-comp id vid sync state)))]
            [next-id (add1 id)])
          id))

;; 把一个**已存在**的 core 视图注册为组件（内容格）。→ (values host id)
(define (host-adopt-view h vid #:sync [sync #f] #:state [state #f])
  (editor-view-ref (host-editor h) vid)                 ; 校验
  (define id (host-next-id h))
  (values (struct-copy host h
            [comps (append (host-comps h) (list (make-comp id vid sync state)))]
            [next-id (add1 id)])
          id))

(define (host-remove-pane h id)
  (find-comp h id)
  (struct-copy host h
    [comps (for/list ([p (in-list (host-comps h))] #:unless (= id (comp-id p))) p)]
    [focus-id (if (= id (host-focus-id h)) #f (host-focus-id h))]))

(define (host-set-pane-state h id st)
  (find-comp h id)
  (struct-copy host h
    [comps (for/list ([p (in-list (host-comps h))])
             (if (= id (comp-id p)) (struct-copy comp p [state st]) p))]))

(define (host-pane-state h id) (comp-state (find-comp h id)))
(define (host-pane-vid h id) (comp-vid (find-comp h id)))

;;; ---------- 焦点 / 布局 / 尺寸 ----------

(define (host-set-focus h id)
  (find-comp h id)
  (struct-copy host h [focus-id id]))

(define (host-set-focus-vid h vid)
  (define p (for/first ([p (in-list (host-comps h))] #:when (= vid (comp-vid p))) p))
  (unless p (error 'host-set-focus-vid "没有 vid = ~a 的组件" vid))
  (struct-copy host h [focus-id (comp-id p)]))

(define (host-focused-vid h)
  (define id (host-focus-id h))
  (and id (comp-vid (find-comp h id))))

(define (host-set-layout h l) (struct-copy host h [layout l]))
(define (host-resize h rows cols) (struct-copy host h [rows rows] [cols cols]))

(define (host-view-at h row col)
  (define l (host-layout h))
  (cond
    [(not l) (values #f #f #f)]
    [else
     (define hit (layout-hit l (host-cols h) (host-rows h) row col))
     (cond
       [(not hit) (values #f #f #f)]
       [else (values (comp-vid (find-comp h (car hit))) (cadr hit) (caddr hit))])]))

;;; ---------- 投影：跑所有组件的 sync ----------

(define (make-ctx h p ed)
  (ctx ed (host-focus-id h) (host-focused-vid h) (comp-id p) (comp-vid p) (host-rows h) (host-cols h)))

(define (run-comp-syncs h)
  (for/fold ([h h]) ([pid (in-list (map comp-id (host-comps h)))])
    (define p (find-comp h pid))
    (define sync (comp-sync p))
    (cond
      [(not sync) h]
      [else
       (define ed (host-editor h))
       (define-values (doc st*) (sync (make-ctx h p ed) (comp-state p)))
       (define h1 (struct-copy host h
                    [comps (for/list ([q (in-list (host-comps h))])
                             (if (= pid (comp-id q)) (struct-copy comp q [state st*]) q))]))
       (cond
         [(not doc) h1]
         [(equal? doc (editor-view-document (host-editor h1) (comp-vid p))) h1]
         [else (struct-copy host h1
                 [editor (editor-view-assign (host-editor h1) (comp-vid p) doc)])])])))

;;; ---------- 分隔带（可选装饰）：竖带画 │、横带画 ─ ----------

(define (add-run s row rn)
  (screen (screen-width s) (screen-height s)
          (for/vector ([r (in-range (screen-height s))])
            (if (= r row)
                (sort (cons rn (screen-row s r)) < #:key run-col)
                (screen-row s r)))
          (screen-cursors s) (screen-regions s)))

(define (draw-gap s g)
  (case (gap-orient g)
    [(v) (for/fold ([s s]) ([r (in-range (gap-y g) (+ (gap-y g) (gap-h g)))])
           (add-run s r (run (gap-x g) "│" 'separator)))]
    [(h) (for/fold ([s s]) ([c (in-range (gap-x g) (+ (gap-x g) (gap-w g)))])
           (add-run s (gap-y g) (run c "─" 'separator)))]))

(define (decorate screen l cols rows)
  (for/fold ([s screen]) ([g (in-list (layout-gaps l 0 0 cols rows))])
    (draw-gap s g)))

;;; ---------- 帧 ----------

;; → (values host screen render selection)
(define (host-frame h)
  (define h1 (run-comp-syncs h))
  (define l (host-layout h1))
  (define rects (if l (layout->rects l 0 0 (host-cols h1) (host-rows h1)) '()))
  (define ed* (editor-set-layout (host-editor h1) rects))
  (define screen (editor-render-layout ed* rects (host-focused-vid h1) (host-cols h1) (host-rows h1)))
  (define screen* (if l (decorate screen l (host-cols h1) (host-rows h1)) screen))
  (define-values (render selection) (screen-patch (host-last-screen h1) screen*))
  (values (struct-copy host h1 [editor ed*] [last-screen screen*]) screen* render selection))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../core/text/document.rkt")

  (define ed0 (editor-open "hello\nworld" 20 5))
  (define h0 (host-open ed0 5 20))
  (define-values (h1 id0) (host-adopt-view h0 0))

  ;; 一个玩具组件：把「焦点 vid」写进自己的文档
  (define (echo-sync ctx st)
    (values (document-open (format "focus=~a" (ctx-focus-vid ctx))) st))
  (define-values (h2 id1) (host-add-document h1 "" 20 1 "*echo*"
                                             #:history? #f #:sync echo-sync #:state #f))
  (define h3 (host-set-layout h2 (vsplit-bottom 1 id0 id1)))
  (define h4 (host-set-focus h3 id0))
  (define-values (h5 screen _r _s) (host-frame h4))

  ;; 组件按 ctx 的焦点信息投影（焦点 = id0 → vid0）
  (check-equal? (editor-view-string (host-editor h5) (host-pane-vid h5 id1)) "focus=0")

  ;; 幂等：内容没变，再 frame 不产生新 editor 值
  (define-values (h6 _s6 _r6 _x6) (host-frame h5))
  (check-true (eq? (host-editor h5) (host-editor h6)))

  ;; 内容窗格 + 组件一起合成到同一屏，状态栏在底行
  (check-equal? (screen->string screen) "hello\nworld\n\n\nfocus=0")

  ;; 命中 → 组件 vid + 局部坐标
  (define-values (vid lr lc) (host-view-at h5 4 3))
  (check-equal? vid (host-pane-vid h5 id1))
  (check-equal? (list lr lc) '(0 3))

  ;; resize：布局跟着重排
  (define h7 (host-resize h5 8 30))
  (define-values (h8 screen8 _r8 _x8) (host-frame h7))
  (check-equal? (screen-width screen8) 30)
  (check-equal? (screen-height screen8) 8)
  (check-equal? (editor-view-height (host-editor h8) (host-pane-vid h8 id0)) 7)

  (displayln "lab/host.rkt: all tests passed"))
