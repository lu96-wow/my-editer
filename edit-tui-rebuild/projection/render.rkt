#lang racket

;;; projection/render.rkt —— State + Engine → panels / chrome / bytes（投影，不输出）
;;; layer  : projection
;;; effect : 无（纯投影：只读 engine，不写 core；输出交给 runtime）

;;;   project-frame  : state engine -> (values panels chrome-entries view-placements)
;;;                    panels = 平铺面板 + 浮层面板（浮层 deep 更高，叠在上面）
;;;   render-frame   : state engine cache -> (values frame-cache bytes)
;;;
;;; 投影**不写 core**：
;;;   · panels 只引用 engine 里的 view 句柄；
;;;   · view 的 viewport 尺寸由 Runtime 在渲染前调用
;;;     `(engine-sync-views! engine view-placements)`；
;;;   · 本模块不 put-bytes、不 flush。
;;;
;;; 浮层（workspace.floats）是**真的 panel + view**：core 的 screen 里就有它，
;;; 所以出现 / 移动 / 消失都由 core 的增量 diff 负责，这里不做任何擦除。
;;;
;;; chrome region（状态栏 / 输入栏）不是 core view：自己按内容区画文本。
;;; 为了避免重复输出，frame-cache 记住上一帧的 chrome 行；只有变化时才：
;;;   · 清掉旧内容区（如果位置变了也清旧矩形）；
;;;   · 画新文本。

(provide (struct-out frame-cache)
         (struct-out chrome-entry)
         project-frame
         project-view-placements
         render-frame)

(require "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/engine.rkt"
         "../projection/geometry.rkt"
         "../projection/status.rkt"
         "../projection/float.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/view/patch.rkt"          ; piece
         "../../core/editor/render.rkt"       ; render-display-patch
         "../../core/text/base/width.rkt"
         "../../edit-tui/core-render/main.rkt")

;;; ════════════════ 结果 / 缓存 ════════════════

(struct chrome-entry (region line rect) #:transparent)
;; region : region-id
;; line   : string（chrome 成员的投影文本）
;; rect   : 内容区 rect（屏幕坐标）

(struct frame-cache (core chrome) #:transparent)
;; core   : core 的 render-cache | #f
;; chrome : (hash/c region-id chrome-entry)  上一帧 chrome
;;
;; 浮层不在这里：它是真的 panel（在 core 的 screen 里），core 的 diff 自己管。

;;; ════════════════ 投影 ════════════════

(define (frame-area state)
  (define w (state-window state))
  (rect 0 0 (window-cols w) (window-rows w)))

(define (active-member reg)
  (for/first ([m (in-list (region-members reg))]
              #:when (equal? (member-key m) (region-active reg)))
    m))

;; → (values panels chrome-entries view-placements)
;;   panels          : (listof core panel)
;;   chrome-entries  : (listof chrome-entry)
;;   view-placements : (listof (list view-id content-rect)) 给 engine-sync-views!
(define (project-frame state engine #:status-parts [status-parts #f])
  (define ws (state-workspace state))
  (define ev (make-engine-view engine))
  (define focus (state-focus state))
  (define-values (rps _cuts) (geometry-solve (workspace-layout ws) (frame-area state)))
  (define panels '())
  (define chromes '())
  (define placements '())
  (for ([rp (in-list rps)])
    (define rid (region-panel-region rp))
    (define reg (workspace-region ws rid))
    (define m (and reg (active-member reg)))
    (define borders (region-panel-borders rp))
    (define r (region-panel-rect rp))
    (define c (region-panel-content rp))
    (cond
      [(and m (view-member? m))
       (define vid (member-key m))
       (define v (engine-view-object engine vid))
       (when v
         (set! placements (cons (list vid c) placements)))
       (define focused? (and focus (equal? focus vid)))
       (set! panels
             (cons (make-panel v r borders
                               #:face (if focused? 'focused-border 'window-border)
                               #:weight (if focused? 1 0))
                   panels))]
      [(and m (chrome-member? m))
       (define line (chrome-line state ev (member-key m) status-parts))
       (set! chromes (cons (chrome-entry rid line c) chromes))
       (set! panels (cons (make-panel #f r borders) panels))]
      [else
       ;; 没有成员的 region（刚拆出来的空窗口 / 关光 view 的 panel）：
       ;; 焦点可能正好在它上面（focus = region-id），给它聚焦边框做视觉反馈。
       (define focused? (and focus (equal? focus rid)))
       (set! panels
             (cons (make-panel #f r borders
                               #:face (if focused? 'focused-border 'window-border)
                               #:weight (if focused? 1 0))
                   panels))]))
  ;; 浮层：不在 layout 里，作为 deep 更高的 panel 叠上去。
  ;; 内容仍是 document/view —— core 的 screen 里就有它，擦除/遮挡由 core 的 diff 负责。
  (for ([fp (in-list (project-floats state ev))])
    (define vid (float-panel-view fp))
    (define v (engine-view-object engine vid))
    (when v
      (define r (float-panel-rect fp))
      (define borders float-borders)
      (set! placements (cons (list vid (rect-content r borders)) placements))
      (set! panels
            (cons (make-panel v r borders #:deep 1 #:face 'focused-border)
                  panels))))
  (values (reverse panels) (reverse chromes) (reverse placements)))

(define (project-view-placements state engine #:status-parts [status-parts #f])
  (define-values (_ps _cs placements) (project-frame state engine #:status-parts status-parts))
  placements)

;;; ════════════════ 渲染 ════════════════

;; 纯投影：返回新 cache + bytes（不 put）。
;; 调用方应先用 project-view-placements + engine-sync-views! 同步 view 尺寸。
(define (render-frame state engine cache #:status-parts [status-parts #f])
  (define-values (panels chromes placements)
    (project-frame state engine #:status-parts status-parts))
  (define area (frame-area state))
  (define focus-id (state-focus state))
  (define focus-view (and focus-id (engine-view-object engine focus-id)))
  (define core-cache (and (frame-cache? cache) (frame-cache-core cache)))
  (define-values (core-cache* rows sels)
    (render-display-patch panels focus-view
                          (rect-w area) (rect-h area)
                          core-cache))
  (define old-chrome (if (frame-cache? cache) (frame-cache-chrome cache) (hash)))
  ;; core 只要重画了任何格子，就可能把 chrome 区域的旧文本擦掉（chrome panel 是空 view），
  ;; 所以强制把 chrome 也重画一遍。chrome 自身没变时，diff 仍只在 force? 下产生 piece。
  (define core-redrew? (or (pair? rows) (pair? sels)))
  (define-values (chrome* chrome-pieces)
    (chrome-diff-pieces old-chrome chromes core-redrew?))
  (define all-pieces (append rows sels chrome-pieces))
  (define out (bytes-append (if cache (bytes) (render-clear))
                            (render-pieces all-pieces)))
  (values (frame-cache core-cache* chrome*) out))

;;; ════════════════ chrome 文本 ════════════════

;; 返回 (values 新 chrome 表 pieces)。只对变化 / 消失的 chrome 产生 piece。
(define (chrome-diff-pieces old-chrome chromes [force? #f])
  (define new-chrome (make-hash))
  (define pieces '())
  (for ([e (in-list chromes)])
    (define rid (chrome-entry-region e))
    (define old (hash-ref old-chrome rid #f))
    (define line (chrome-entry-line e))
    (define r (chrome-entry-rect e))
    (hash-set! new-chrome rid e)
    (unless (and (not force?)
                 old
                 (equal? (chrome-entry-line old) line)
                 (equal? (chrome-entry-rect old) r))
      ;; 位置变了：先清旧矩形；再清新矩形并画新文本。
      (when (and old (not (equal? (chrome-entry-rect old) r)))
        (set! pieces (append pieces (clear-rect-pieces (chrome-entry-rect old)))))
      (set! pieces (append pieces (clear-rect-pieces r)))
      (when (and line (positive? (string-length line)))
        (set! pieces (append pieces (list (text-piece r line)))))))
  ;; 消失的 chrome：清掉上一帧的矩形。
  (for ([(rid old) (in-hash old-chrome)] #:unless (hash-has-key? new-chrome rid))
    (set! pieces (append pieces (clear-rect-pieces (chrome-entry-rect old)))))
  (values new-chrome pieces))

(define (clear-rect-pieces r)
  (define w (rect-w r))
  (define h (rect-h r))
  (if (or (<= w 0) (<= h 0))
      '()
      (for/list ([i (in-range h)])
        (piece (+ (rect-y r) i) (rect-x r) (make-string w #\space) #f))))

(define (text-piece r line)
  (define w (rect-w r))
  (define text (truncate-to-width line w))
  (piece (rect-y r) (rect-x r) text #f))

(define (truncate-to-width s w)
  (cond
    [(<= w 0) ""]
    [(<= (string-display-width s) w) s]
    [else
     (let loop ([i 0] [col 0] [acc '()])
       (cond
         [(>= i (string-length s)) (list->string (reverse acc))]
         [else
          (define c (string-ref s i))
          (define cw (char-display-width c))
          (if (> (+ col cw) w)
              (list->string (reverse acc))
              (loop (add1 i) (+ col cw) (cons c acc)))]))]))
