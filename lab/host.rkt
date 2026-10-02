#lang racket

;;; ============================================================================
;;; host.rkt —— 通用宿主：全局状态 + 组件运行时
;;; ============================================================================
;;;
;;; 骨架里唯一持全局状态的地方。它只认识「组件协议」与「effect 词汇」，
;;; **不认识 tree、不认识任何具体组件、不认识后端**。
;;;
;;;   host = editor(core) × panes × layout × focus × size
;;;   pane = { kind, vid, sync, input, pointer, focusable?, state }
;;;   ctx  = 给组件的只读快照
;;;
;;; 一个组件只做两件事：
;;;   sync  : ctx × state        → (values document state cursor)   投影
;;;   input : ctx × state × input → (values state (listof effect))   处理
;;;
;;; 会动全局结构的动作（开/关文档、加/关视图、聚焦）只表达成 effect，
;;; 由本模块统一解释 —— 全局状态只有一个写口。
;;;
;;; 统一配置在别处：init.rkt 用一张 pane 表 + 一个 layout 值声明整个应用。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "layout.rkt"
         "input.rkt"
         "fs.rkt"
         racket/file)

(provide
 ;; 类型
 (struct-out pane)
 (struct-out host)
 (struct-out ctx)
 ;; pane / host 存取
 host-pane host-set-pane host-pane-vid host-pane-kind host-focus-vid host-pid-of-kind
 host-pane-rect make-ctx
 ;; 文档生命周期（workspace）
 host-opened host-path host-open-views host-shown-views host-pane-of-view
 host-open host-close-document host-close-view host-add-view
 ;; 焦点
 host-set-focus host-show-view host-focus-view
 ;; 运行时
 host-dispatch host-project! host-render apply-effects handle)

;;; ============================================================================
;;; 状态
;;; ============================================================================

(struct pane (kind vid sync input pointer focusable? state) #:transparent)
;; kind       : symbol                       组件种类（'tree / …）
;; vid        : vid                          它渲染到哪个 core 视图
;; sync       : #f | (ctx state → (values document state cursor))
;; input      : #f | (ctx state input → (values state (listof effect)))
;; pointer    : #f | (ctx state input 行 列 → (values state (listof effect)))
;; focusable? : bool

(struct host (editor opened panes layout focus editor-pane rows cols) #:transparent)
;; editor      : core editor（所有文档 + 视图）
;; opened      : hash（path → did）
;; panes       : hash（pane-id → pane）
;; layout      : layout 值（叶 = pane-id）
;; focus       : pane-id
;; editor-pane : pane-id | #f（"打开文件落到哪个窗格"；骨架里没有编辑格 → #f）
;; rows / cols : 屏幕尺寸

;; 组件拿到的**只读**上下文。
(struct ctx (pid vid pane-w pane-h
             editor editor-pane editor-vid focus
             open-views opened shown-views)
  #:transparent)

;;; ---------- pane / host 存取 ----------

(define (host-pane h pid) (hash-ref (host-panes h) pid))
(define (host-set-pane h pid p) (struct-copy host h [panes (hash-set (host-panes h) pid p)]))
(define (host-pane-vid h pid) (pane-vid (host-pane h pid)))
(define (host-pane-kind h pid) (pane-kind (host-pane h pid)))
(define (host-focus-vid h) (host-pane-vid h (host-focus h)))

(define (host-pid-of-kind h kind)
  (for/first ([(id p) (in-hash (host-panes h))] #:when (eq? (pane-kind p) kind)) id))

;; pane 在布局里的矩形。
(define (host-pane-rect h pid)
  (for/first ([r (in-list (layout->rects (host-layout h) 0 0 (host-cols h) (host-rows h)))]
              #:when (= pid (lrect-id r)))
    r))

(define (make-ctx h pid)
  (define p (host-pane h pid))
  (define r (host-pane-rect h pid))
  (define epid (host-editor-pane h))
  (ctx pid (pane-vid p)
       (if r (lrect-w r) 40) (if r (lrect-h r) 10)
       (host-editor h) epid (and epid (host-pane-vid h epid)) (host-focus h)
       (host-open-views h) (host-opened h) (host-shown-views h)))

;;; ============================================================================
;;; 文档生命周期（workspace：文件路径 ↔ editor 文档）
;;; ============================================================================

(define default-view-size 80)
(define default-view-height 24)

(define (host-path h did)
  (for/first ([(p d) (in-hash (host-opened h))] #:when (= d did)) p))

;; 某个视图现在被哪个 pane 显示（#f = 没有）。
(define (host-pane-of-view h vid)
  (for/first ([(pid p) (in-hash (host-panes h))] #:when (equal? vid (pane-vid p))) pid))

;; 当前被某个 pane 显示的视图集合。
(define (host-shown-views h)
  (for/list ([(pid p) (in-hash (host-panes h))]) (pane-vid p)))

;; 视图表里该列出的「已打开视图」：除树/状态栏这些内部文档之外的视图，按 editor 顺序。
(define (host-open-views h)
  (define ed (host-editor h))
  (define internal
    (for/list ([(pid p) (in-hash (host-panes h))]
               #:when (memq (pane-kind p) '(tree status)))
      (editor-view-document-id ed (pane-vid p))))
  (for/list ([v (in-list (editor-views ed))] #:unless (memq (view-did v) internal))
    (view-id v)))

;; 打开路径：已开→原样；否则读文件建文档 + 一个视图（未显示，等有编辑格时再显示）。
(define (host-open h path)
  (define existing (hash-ref (host-opened h) path #f))
  (cond
    [existing h]
    [(not (and (file-exists? path) (not (directory-exists? path)))) h]
    [else
     (define text (fs-read path))
     (define-values (ed1 did)
       (editor-add-document (host-editor h) text (path->string (file-name-from-path path))))
     (define-values (ed2 _vid)
       (editor-add-view ed1 did default-view-size default-view-height
                        'free #f #:line-numbers? #t))
     (struct-copy host h
       [editor ed2]
       [opened (hash-set (host-opened h) path did)])]))

(define (host-close-document h did)
  (editor-document-entry (host-editor h) did)         ; 校验
  (struct-copy host h
    [editor (editor-close-document (host-editor h) did)]
    [opened (for/hash ([(p d) (in-hash (host-opened h))] #:unless (= d did)) (values p d))]))

(define (host-close-view h vid)
  (editor-view-ref (host-editor h) vid)               ; 校验
  (struct-copy host h [editor (editor-close-view (host-editor h) vid)]))

(define (host-add-view h did point)
  (define-values (ed vid)
    (editor-add-view (host-editor h) did default-view-size default-view-height
                     'free #f #:line-numbers? #t))
  (when point (editor-view-set-point! ed vid point))
  (struct-copy host h [editor ed]))

;;; ============================================================================
;;; 焦点 / 显示
;;; ============================================================================

(define (host-set-focus h pid)
  (host-pane h pid)                                   ; 校验
  (struct-copy host h [focus pid]
               [editor-pane (if (eq? (host-pane-kind h pid) 'buffer)
                                pid (host-editor-pane h))]))

;; 让某个 pane 显示一个**已经存在**的视图。
(define (host-show-view h pid vid)
  (editor-view-ref (host-editor h) vid)               ; 校验
  (define p (host-pane h pid))
  (define h1 (host-set-pane h pid (struct-copy pane p [vid vid])))
  (define h2 (struct-copy host h1
               [editor-pane (if (eq? (pane-kind p) 'buffer) pid (host-editor-pane h1))]))
  (editor-view-set-size! (host-editor h2) vid
                         (let ([r (host-pane-rect h2 pid)]) (if r (lrect-w r) default-view-size))
                         (let ([r (host-pane-rect h2 pid)]) (if r (lrect-h r) default-view-height)))
  h2)

;; 聚焦显示某视图的窗格；没显示就显示到 editor-pane 再聚焦；都没有则原样。
(define (host-focus-view h vid)
  (cond
    [(host-pane-of-view h vid) => (lambda (pid) (host-set-focus h pid))]
    [else
     (define epid (host-editor-pane h))
     (cond [(not epid) h]
           [else (host-set-focus (host-show-view h epid vid) epid)])]))

;;; ============================================================================
;;; 运行时：投影 + 分发 + effect 解释
;;; ============================================================================

;; 跑每个 pane 的 sync，把文档写进它的 view（幂等；cursor 非 #f 时落点）。
(define (host-project! h)
  (for/fold ([h h]) ([pid (in-list (hash-keys (host-panes h)))])
    (define p (host-pane h pid))
    (define sync (pane-sync p))
    (cond
      [(not sync) h]
      [else
       (define-values (doc st cur) (sync (make-ctx h pid) (pane-state p)))
       (define h1 (host-set-pane h pid (struct-copy pane p [state st])))
       (cond
         [(not doc) h1]
         [else
          (editor-view-assign! (host-editor h1) (pane-vid p) doc)
          (when cur (editor-view-set-point! (host-editor h1) (pane-vid p) cur))
          h1])])))

;; 输入 → 命中 pane（鼠标）或焦点 pane（键盘）→ state + effects → 解释 effects。
(define (host-dispatch h in)
  (cond
    [(or (mouse? in) (wheel? in))
     (define-values (pr pc) (pointer-position in))
     (define pid (layout-hit (host-layout h) (host-cols h) (host-rows h) pr pc))
     (cond
       [(not pid) h]
       [else
        (define p (host-pane h pid))
        (define h1 (if (pane-focusable? p) (host-set-focus h pid) h))
        (define f (pane-pointer p))
        (cond
          [(not f) h1]
          [else
           (define r (host-pane-rect h1 pid))
           (define-values (st eff)
             (f (make-ctx h1 pid) (pane-state p) in
                (- pr (lrect-y r)) (- pc (lrect-x r))))
           (apply-effects (host-set-pane h1 pid (struct-copy pane p [state st])) eff)])])]
    [else
     (define pid (host-focus h))
     (define p (host-pane h pid))
     (define f (pane-input p))
     (cond
       [(not f) h]
       [else
        (define-values (st eff) (f (make-ctx h pid) (pane-state p) in))
        (apply-effects (host-set-pane h pid (struct-copy pane p [state st])) eff)])]))

;; effect = 会把全局结构改掉的动作。组件只描述，host 统一执行。
;;   (list 'open path)
;;   (list 'close-document did)
;;   (list 'close-view vid)
;;   (list 'new-view did point)
;;   (list 'show-view pid vid)
;;   (list 'focus pid)
;;   (list 'focus-view vid)
(define (apply-effects h effs)
  (for/fold ([h h]) ([e (in-list effs)]) (apply-effect h e)))

(define (apply-effect h e)
  (match e
    [(list 'open path)          (host-open h path)]
    [(list 'close-document did) (host-close-document h did)]
    [(list 'close-view vid)     (host-close-view h vid)]
    [(list 'new-view did point) (host-add-view h did point)]
    [(list 'show-view pid vid)  (host-show-view h pid vid)]
    [(list 'focus pid)          (host-set-focus h pid)]
    [(list 'focus-view vid)     (host-focus-view h vid)]
    [else h]))

;; 输入入口：resize + 分发，最后投影一次（这样处理完状态就是对的）。
(define (handle h in)
  (define h1
    (cond
      [(resize? in) (struct-copy host h [rows (resize-rows in)] [cols (resize-cols in)])]
      [else (host-dispatch h in)]))
  (host-project! h1))

;;; ---------- 帧 ----------

;; project! → layout 解析成 rects → 尺寸落到 view → 合成 screen。→ (values host screen)
(define (host-render h)
  (define h1 (host-project! h))
  (define lrs (layout->rects (host-layout h1) 0 0 (host-cols h1) (host-rows h1)))
  (define rects (for/list ([r (in-list lrs)])
                  (rect (host-pane-vid h1 (lrect-id r))
                        (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r) 0)))
  (define ed (editor-set-layout (host-editor h1) rects))
  (define h2 (struct-copy host h1 [editor ed]))
  (values h2
          (editor-render-layout ed rects (host-focus-vid h2) (host-cols h2) (host-rows h2))))

;;; ============================================================================
;;; 测试（宿主：文档生命周期 + effect + 帧）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/view/base/screen.rkt")

  (define d (make-temporary-file "rbhost-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\n" f #:exists 'replace)

  ;; 一个只渲染一个空文档的哑组件（#f = 不投影），用于测宿主本身。
  (define ed (editor-open "" 20 5 #:line-numbers? #f))
  (define panes (hash 0 (pane 'tree 0 #f #f #f #t #f)))
  (define h0 (host ed (hash) panes (lpane 0) 0 #f 5 20))

  ;; 帧：screen 尺寸 = host 尺寸
  (define-values (_h1 screen) (host-render h0))
  (check-equal? (screen-width screen) 20)
  (check-equal? (screen-height screen) 5)

  ;; 打开 / 关闭文档
  (define h2 (host-open h0 f))
  (check-true (hash-has-key? (host-opened h2) f))
  (define did (hash-ref (host-opened h2) f))
  (check-equal? (document->string (document-entry-document (editor-document-entry (host-editor h2) did)))
                "hello\n")
  (check-equal? (length (host-open-views h2)) 1)
  (define h3 (host-close-document h2 did))
  (check-false (hash-has-key? (host-opened h3) f))
  (check-equal? (length (host-open-views h3)) 0)

  ;; effect 解释：open 一步到位
  (define h4 (apply-effects h0 (list (list 'open f))))
  (check-true (hash-has-key? (host-opened h4) f))

  ;; 打开不存在的文件 = no-op
  (check-equal? (host-opened (host-open h0 (build-path d "nope"))) (hash))

  (delete-directory/files d)
  (displayln "lab/host.rkt: all tests passed"))
