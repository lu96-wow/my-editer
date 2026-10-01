#lang racket

;;; ============================================================================
;;; state.rkt —— 全局状态 + 生命周期 + 组件运行时
;;; ============================================================================
;;;
;;; 这是 lab 的「状态块」：**唯一**持有并改写全局状态的地方。
;;; 别的块（tree / buffer / status / command）都只经这里定义的语言说话。
;;;
;;; ── 全局状态 app ──────────────────────────────────────────────────────────
;;;   editor       core 的 editor（所有文档 + 视图）
;;;   opened       hash（path → did）
;;;   panes        pane-id → pane（每个 pane 是一个组件 + 它的局部状态）
;;;   layout       布局值（叶 = pane-id；见 layout.rkt）
;;;   focus        pane-id
;;;   editor-pane  pane-id（打开文件落到哪个编辑格）
;;;   rows / cols  屏幕尺寸
;;;   quit? …      退出流程
;;;
;;; ── pane（组件）────────────────────────────────────────────────────────────
;;;   (pane kind vid sync input pointer focusable? state)
;;;     sync       ctx × state → (values document state cursor)   投影（#f = 不投影）
;;;     input      ctx × state × input        → (values state effects)
;;;     pointer    ctx × state × input × 行 × 列 → (values state effects)
;;;   **组件不碰 app**：它拿到只读 ctx + 自己的 state，只返回 (state ⊕ effects)。
;;;   凡是会动全局结构的动作（开/关文档、加/关视图、切焦点、分格、退出）都表达成
;;;   effect，由本模块统一解释。于是每个组件都能独立实现、独立测试。
;;;
;;; ── 投影 / 分发 ───────────────────────────────────────────────────────────
;;;   project!   跑每个 pane 的 sync，把文档写进它的 view（**每处都重建**，幂等）
;;;   dispatch   把输入交给焦点 pane 的 input，然后 apply-effects
;;;
;;; 结构操作（增/删文档、视图）走 core 的 editor-*（返回新 editor）；
;;; 编辑 / 光标 / 视口是 core 的就地命令（box 改），不动 app 值。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/selection.rkt"
         "layout.rkt"
         "input.rkt"
         "fs.rkt"
         racket/file)

(provide
 ;; ---------- 类型 ----------
 (struct-out pane)
 (struct-out app)
 (struct-out ctx)

 ;; ---------- pane / app 存取 ----------
 app-pane app-set-pane app-pane-vid app-focus-vid app-pid-of-kind
 app-pane-rect app-pane-height app-pane-kind
 make-ctx

 ;; ---------- 文档管理 ----------
 app-path app-first-editor-pane
 app-open app-show app-close app-save app-save-did app-dirty?
 app-show-view app-close-view app-new-view app-focus-view
 app-pane-of-view app-open-views

 ;; ---------- 退出流程 ----------
 quit-request quit-save-current quit-skip-current quit-cancel
 quit-answer app-quit-message

 ;; ---------- 焦点 ----------
 focus-set focusable-leaves focus-step focus-next! focus-prev! focus-direction!

 ;; ---------- 布局 ----------
 add-editor-pane layout-split! layout-close! editor-resize-focus

 ;; ---------- 运行时 ----------
 dispatch project! apply-effects)

;;; ============================================================================
;;; 全局状态
;;; ============================================================================

;; 一个组件注册项。sync / input / pointer 都是注入的纯逻辑（见文件头）。
(struct pane (kind vid sync input pointer focusable? state) #:transparent)
;; kind       : symbol                        组件种类（'tree / 'buffer / 'status …）
;; vid        : vid                           它渲染到哪个 core 视图
;; sync       : #f | (ctx state → (values document state cursor))
;; input      : #f | (ctx state input → (values state (listof effect)))
;; pointer    : #f | (ctx state input 行 列 → (values state (listof effect)))
;; focusable? : bool

(struct app (editor opened panes layout focus editor-pane rows cols
              quit? quit-ask quit-rest)
  #:transparent)
;; quit?     : 置 #t 后主循环退出
;; quit-ask  : #f | did —— 正在问"是否保存"的文档
;; quit-rest : (listof did) —— 还没问的文档

;; 组件投影 / 处理时拿到的**只读**上下文。
(struct ctx (pid vid pane-w pane-h
             editor editor-pane editor-vid focus
             shown-views open-views opened quit-ask quit-message)
  #:transparent)

;;; ---------- pane / app 存取 ----------

(define (app-pane a pid) (hash-ref (app-panes a) pid))
(define (app-set-pane a pid p) (struct-copy app a [panes (hash-set (app-panes a) pid p)]))
(define (app-pane-vid a pid) (pane-vid (app-pane a pid)))
(define (app-pane-kind a pid) (pane-kind (app-pane a pid)))
(define (app-focus-vid a) (app-pane-vid a (app-focus a)))

(define (app-pid-of-kind a kind)
  (for/first ([(id p) (in-hash (app-panes a))] #:when (eq? (pane-kind p) kind)) id))

;; pane 在布局里的矩形（渲染 / 命中 / 新建视图定尺寸都用它）。
(define (app-pane-rect a pid)
  (for/first ([r (in-list (layout->rects (app-layout a) 0 0 (app-cols a) (app-rows a)))]
              #:when (= pid (lrect-id r)))
    r))

(define (rect-w-or a pid fallback)
  (if (app-pane-rect a pid) (lrect-w (app-pane-rect a pid)) fallback))
(define (rect-h-or a pid fallback)
  (if (app-pane-rect a pid) (lrect-h (app-pane-rect a pid)) fallback))

(define (app-pane-height a pid)
  (if (app-pane-rect a pid) (lrect-h (app-pane-rect a pid)) (app-rows a)))

;; 组件的只读 ctx：把全局状态投影成它需要的那几个量。
(define (make-ctx a pid)
  (define p (app-pane a pid))
  (define r (app-pane-rect a pid))
  (define epid (app-editor-pane a))
  (ctx pid (pane-vid p)
       (if r (lrect-w r) 40) (if r (lrect-h r) 10)
       (app-editor a) epid (and epid (app-pane-vid a epid)) (app-focus a)
       (app-shown-views a) (app-open-views a) (app-opened a)
       (app-quit-ask a) (app-quit-message a)))

;;; ============================================================================
;;; 文档管理（文件路径 ↔ editor 文档 + 显示 / 保存 / 关闭）
;;; ============================================================================

(define (app-path a did)
  (for/first ([(p d) (in-hash (app-opened a))] #:when (= d did)) p))

(define (app-first-editor-pane a)
  (for/first ([(id p) (in-hash (app-panes a))] #:when (eq? (pane-kind p) 'buffer)) id))

;; 某个视图现在被哪个 pane 显示（#f = 没有任何 pane 显示它）。
(define (app-pane-of-view a vid)
  (for/first ([(pid p) (in-hash (app-panes a))] #:when (equal? vid (pane-vid p))) pid))

;; 当前被某个 pane 显示的视图集合。
(define (app-shown-views a)
  (for/list ([(pid p) (in-hash (app-panes a))]) (pane-vid p)))

;; 树里该列出的「已打开视图」：Editor 里除树 / 状态栏这些内部文档之外的视图，
;; 按 editor 顺序（含当前没被任何 pane 显示的视图）。
(define (app-open-views a)
  (define ed (app-editor a))
  (define internal
    (for/list ([(pid p) (in-hash (app-panes a))]
               #:when (memq (pane-kind p) '(tree status)))
      (editor-view-document-id ed (pane-vid p))))
  (for/list ([v (in-list (editor-views ed))] #:unless (memq (view-did v) internal))
    (view-id v)))

;; 让某个 pane 显示一个**已经存在**的视图（复用，不新建、不关旧视图）。
(define (app-show-view a pid vid)
  (define shown (app-pane-of-view a vid))
  (cond
    [(and shown (not (= shown pid))) a]
    [else
     (editor-view-ref (app-editor a) vid)          ; 校验 vid
     (define p (app-pane a pid))
     (define a1 (app-set-pane a pid (struct-copy pane p [vid vid])))
     (define a2 (struct-copy app a1 [editor-pane (if (eq? (pane-kind p) 'buffer) pid (app-editor-pane a1))]))
     ;; 视图尺寸对齐当前窗格（ensure / 鼠标换算依赖它）。
     (editor-view-set-size! (app-editor a2) vid (rect-w-or a2 pid 40) (rect-h-or a2 pid 10))
     a2]))

;; 若 pane 当前显示的是一个**空且非文件**的占位 scratch（且是该文档唯一视图），
;; 就把它连同文档一起丢掉 —— 切到真正要显示的文档前先清掉，避免视图表里长长一串 *scratch*。
(define (drop-blank-scratch a pid)
  (define ed (app-editor a))
  (define vid (pane-vid (app-pane a pid)))
  (define did (editor-view-document-id ed vid))
  (define file-doc? (for/or ([d (in-hash-values (app-opened a))]) (= d did)))
  (define view-count (for/sum ([x (in-list (editor-views ed))] #:when (= did (view-did x))) 1))
  (cond
    [(and (not file-doc?)
          (= 1 view-count)
          (string=? "" (editor-view-string ed vid)))
     (struct-copy app a [editor (editor-close-document ed did)])]
    [else a]))

;; 让某个 pane 显示某文档。已有视图（同一 pane 或未显示的）复用；
;; 否则新建一个视图；**不关旧视图** —— 视图留在 editor 里，由树的视图模式管理。
(define (app-show a pid did)
  (editor-document-entry (app-editor a) did)        ; 校验 did
  (define a0 (drop-blank-scratch a pid))
  (define ed (app-editor a0))
  (define v (first-view-of-document ed did))
  (define shown (and v (app-pane-of-view a0 (view-id v))))
  (cond
    [(and v (or (not shown) (= shown pid))) (app-show-view a0 pid (view-id v))]
    [else
     (define-values (ed2 vid)
       (editor-add-view ed did (rect-w-or a0 pid 40) (rect-h-or a0 pid 10)
                        'free #f #:line-numbers? #t))
     (app-show-view (struct-copy app a0 [editor ed2]) pid vid)]))

;; 打开路径：已开复用；否则读文件建文档，再显示到 editor-pane。
(define (app-open a path)
  (define target (app-editor-pane a))
  (define existing (hash-ref (app-opened a) path #f))
  (cond
    [(or (not target) (not (hash-has-key? (app-panes a) target))) a]
    [existing (app-show a target existing)]
    [(not (and (file-exists? path) (not (directory-exists? path)))) a]
    [else
     (define text (fs-read path))
     (define-values (ed* did)
       (editor-add-document (app-editor a) text (path->string (file-name-from-path path))))
     (app-show (struct-copy app a [editor ed*]
                            [opened (hash-set (app-opened a) path did)])
               target did)]))

;; 关闭文档：连带它**所有**视图一起去掉；显示过它的编辑格各自换回空 scratch。
(define (app-close a did)
  (editor-document-entry (app-editor a) did)        ; 校验 did
  (define ed (app-editor a))
  (define pids
    (for/list ([(pid p) (in-hash (app-panes a))]
               #:when (and (eq? (pane-kind p) 'buffer)
                           (= did (editor-view-document-id ed (pane-vid p)))))
      pid))
  (define ed1 (editor-close-document ed did))
  (define a1 (struct-copy app a [editor ed1]
               [opened (for/hash ([(p d) (in-hash (app-opened a))] #:unless (= d did))
                         (values p d))]))
  (for/fold ([acc a1]) ([pid (in-list pids)])
    (define-values (ed2 _did vid)
      (editor-add-document-view (app-editor acc) "" (rect-w-or acc pid 40) (rect-h-or acc pid 10)
                                "*scratch*" #:line-numbers? #t))
    (app-set-pane (struct-copy app acc [editor ed2]) pid
                  (struct-copy pane (app-pane acc pid) [vid vid]))))

;; 关闭**一个视图**。若它正被某编辑格显示，同格改显同文档的另一个视图（没有就换 scratch）；
;; 若这是该文档最后一个视图，文档也一并关掉并移出 opened。
(define (app-close-view a vid)
  (define ed (app-editor a))
  (define v (editor-view-ref ed vid))               ; 校验 vid
  (define did (view-did v))
  (define pid (app-pane-of-view a vid))
  (define ed1 (editor-close-view ed vid))
  (define a1 (struct-copy app a [editor ed1]))
  (define a2
    (cond
      [(not pid) a1]
      [else
       (define alt (first-view-of-document ed1 did))
       (cond
         [alt (app-show-view a1 pid (view-id alt))]
         [else
          (define-values (ed2 _did2 vid2)
            (editor-add-document-view ed1 "" (rect-w-or a1 pid 40) (rect-h-or a1 pid 10)
                                      "*scratch*" #:line-numbers? #t))
          (app-set-pane (struct-copy app a1 [editor ed2]) pid
                        (struct-copy pane (app-pane a1 pid) [vid vid2]))])]))
  (define still? (for/or ([x (in-list (editor-views (app-editor a2)))]) (= did (view-did x))))
  (cond
    [still? a2]
    [else
     (struct-copy app a2
       [editor (editor-close-document (app-editor a2) did)]
       [opened (for/hash ([(p d) (in-hash (app-opened a2))] #:unless (= d did)) (values p d))])]))

;; 给某文档再开一个视图，显示到 editor-pane 并聚焦。
(define (app-new-view a did point)
  (define target (app-editor-pane a))
  (cond
    [(not target) a]
    [else
     (define-values (ed2 vid)
       (editor-add-view (app-editor a) did (rect-w-or a target 40) (rect-h-or a target 10)
                        'free #f #:line-numbers? #t))
     (when point (editor-view-set-point! ed2 vid point))
     (focus-set (app-show-view (struct-copy app a [editor ed2]) target vid) target)]))

;; 聚焦显示某视图的窗格；没显示就显示到 editor-pane 再聚焦。
(define (app-focus-view a vid)
  (define pid (app-editor-pane a))
  (cond
    [(app-pane-of-view a vid) (focus-set a (app-pane-of-view a vid))]
    [(not pid) a]
    [else (focus-set (app-show-view a pid vid) pid)]))

;; 保存某个编辑格当前文档（有路径才写）。
(define (app-save a pid)
  (define ed (app-editor a))
  (define vid (app-pane-vid a pid))
  (define path (app-path a (editor-view-document-id ed vid)))
  (cond
    [path (display-to-file (editor-view-string ed vid) path #:exists 'replace) a]
    [else a]))

;; 按文档 id 保存（退出时用，文档可能没显示在任何编辑格）。
(define (app-save-did a did)
  (define path (app-path a did))
  (cond
    [path (display-to-file (document->string (document-entry-document (editor-document-entry (app-editor a) did)))
                           path #:exists 'replace) a]
    [else a]))

;; 文档当前文本与磁盘不一致？（无路径 / 读到 #f → 视为脏）
(define (app-dirty? a did)
  (define path (app-path a did))
  (and path
       (let ([on-disk (if (file-exists? path) (file->string path) #f)]
             [cur (document->string (document-entry-document (editor-document-entry (app-editor a) did)))])
         (not (equal? on-disk cur)))))

;;; ============================================================================
;;; 退出（逐个问是否保存）
;;; ============================================================================

(define (quit-advance a)
  (define rest (app-quit-rest a))
  (cond
    [(null? rest) (struct-copy app a [quit? #t] [quit-ask #f] [quit-rest '()])]
    [else (struct-copy app a [quit-ask (car rest)] [quit-rest (cdr rest)])]))

;; 请求退出：有脏文档则从第一个开始问；否则直接退出。
(define (quit-request a)
  (define dirty (for/list ([did (in-list (hash-values (app-opened a)))] #:when (app-dirty? a did)) did))
  (cond
    [(null? dirty) (struct-copy app a [quit? #t] [quit-ask #f] [quit-rest '()])]
    [else (struct-copy app a [quit? #f] [quit-ask (car dirty)] [quit-rest (cdr dirty)])]))

(define (quit-save-current a) (quit-advance (app-save-did a (app-quit-ask a))))
(define (quit-skip-current a) (quit-advance a))
(define (quit-cancel a) (struct-copy app a [quit-ask #f] [quit-rest '()]))

;; 状态栏显示的问题（或 #f）。
(define (app-quit-message a)
  (define did (app-quit-ask a))
  (and did
       (let ([path (app-path a did)])
         (format "保存 ~a？(y/n)  Esc 取消"
                 (if path (path->string (file-name-from-path path))
                     (editor-document-name (app-editor a) did))))))

;; 退出问答的按键处理（y 保存 / n 跳过 / Esc 取消）。
(define (plain-key? in)
  (and (key? in) (not (key-ctrl? in)) (not (key-alt? in)) (not (key-meta? in))))

(define (quit-answer a in)
  (cond
    [(plain-key? in)
     (define n (key-name in))
     (cond
       [(and (char? n) (char=? (char-downcase n) #\y)) (quit-save-current a)]
       [(and (char? n) (char=? (char-downcase n) #\n)) (quit-skip-current a)]
       [(eq? n 'escape) (quit-cancel a)]
       [else a])]
    [else a]))

;;; ============================================================================
;;; 焦点
;;; ============================================================================

(define (focus-set a pid)
  (define p (app-pane a pid))
  (struct-copy app a [focus pid]
               [editor-pane (if (eq? (pane-kind p) 'buffer) pid (app-editor-pane a))]))

(define (focusable-leaves a)
  (filter (lambda (pid) (pane-focusable? (app-pane a pid))) (layout-leaves (app-layout a))))

(define (focus-step a step)
  (define leaves (focusable-leaves a))
  (cond
    [(null? leaves) a]
    [else
     (define cur (app-focus a))
     (define i (for/first ([p (in-list leaves)] [i (in-naturals)] #:when (= p cur)) i))
     (define ni (if i (modulo (+ i step) (length leaves)) 0))
     (focus-set a (list-ref leaves ni))]))

(define (focus-next! a) (focus-step a 1))
(define (focus-prev! a) (focus-step a -1))

(define (center-x r) (+ (lrect-x r) (quotient (lrect-w r) 2)))
(define (center-y r) (+ (lrect-y r) (quotient (lrect-h r) 2)))

;; 按方向找最近的可聚焦 pane。
(define (focus-direction! a dir)
  (define cur (app-pane-rect a (app-focus a)))
  (cond
    [(not cur) a]
    [else
     (define cands (for/list ([pid (in-list (focusable-leaves a))] #:unless (= pid (app-focus a)))
                     (cons pid (app-pane-rect a pid))))
     (define (ok? r)
       (case dir
         [(left)  (<= (+ (lrect-x r) (lrect-w r)) (lrect-x cur))]
         [(right) (>= (lrect-x r) (+ (lrect-x cur) (lrect-w cur)))]
         [(up)    (<= (+ (lrect-y r) (lrect-h r)) (lrect-y cur))]
         [(down)  (>= (lrect-y r) (+ (lrect-y cur) (lrect-h cur)))]))
     (define (dist r)
       (case dir
         [(left right) (+ (abs (- (lrect-x r) (lrect-x cur))) (abs (- (center-y r) (center-y cur))))]
         [(up down)    (+ (abs (- (lrect-y r) (lrect-y cur))) (abs (- (center-x r) (center-x cur))))]))
     (define best
       (for/fold ([best #f]) ([pr (in-list cands)])
         (define pid (car pr)) (define r (cdr pr))
         (if (ok? r)
             (let ([d (dist r)]) (if (or (not best) (< d (car best))) (cons d pid) best))
             best)))
     (if best (focus-set a (cdr best)) a)]))

;;; ============================================================================
;;; 布局
;;; ============================================================================

;; 新建一个编辑格 pane（空 scratch）。
(define (add-editor-pane a)
  (define npid (add1 (for/fold ([m -1]) ([(id _p) (in-hash (app-panes a))]) (max m id))))
  (define-values (ed2 _did vid)
    (editor-add-document-view (app-editor a) "" 40 10 "*scratch*" #:line-numbers? #t))
  (define a1 (struct-copy app a [editor ed2]))
  (values (app-set-pane a1 npid (pane 'buffer vid #f #f #f #t #f)) npid))

;; dir = 'h（左右分）| 'v（上下分）；只对编辑格生效。
(define (layout-split! a dir)
  (define pid (app-focus a))
  (cond
    [(not (eq? (pane-kind (app-pane a pid)) 'buffer)) a]
    [else
     (define w (if (app-pane-rect a pid) (lrect-w (app-pane-rect a pid)) 20))
     (define-values (a1 npid) (add-editor-pane a))
     (define sub (if (eq? dir 'h)
                     (hsplit-left (max 1 (quotient w 2)) (lpane pid) (lpane npid) 1)
                     (vsplit (lpane pid) (lpane npid) 1)))
     (focus-set (struct-copy app a1 [layout (layout-replace (app-layout a1) pid sub)]) npid)]))

;; 调**焦点 pane** 的宽度：delta > 0 变宽，< 0 变窄（改最近的水平切分边界）。
(define (editor-resize-focus a delta)
  (define-values (l* done?) (layout-resize (app-layout a) (app-focus a) delta))
  (if done? (struct-copy app a [layout l*]) a))

;; 关掉当前编辑格（树 / 状态栏不关）。
(define (layout-close! a)
  (define pid (app-focus a))
  (cond
    [(not (eq? (pane-kind (app-pane a pid)) 'buffer)) a]
    [else
     (define ed (editor-close-view (app-editor a) (pane-vid (app-pane a pid))))
     (define layout* (or (layout-remove (app-layout a) pid) (app-layout a)))
     (define a1 (struct-copy app a [editor ed]
                          [panes (hash-remove (app-panes a) pid)]
                          [layout layout*]))
     (define a2 (if (= (app-editor-pane a1) pid)
                    (struct-copy app a1 [editor-pane (or (app-first-editor-pane a1) #f)])
                    a1))
     (define leaves (focusable-leaves a2))
     (focus-set a2 (if (null? leaves) (app-focus a2) (car leaves)))]))

;;; ============================================================================
;;; 运行时：投影 + 分发 + effect 解释
;;; ============================================================================

;; 跑每个 pane 的 sync，把文档写进它的 view（幂等；cursor 非 #f 时落点）。
(define (project! a)
  (for/fold ([a a]) ([pid (in-list (hash-keys (app-panes a)))])
    (define p (app-pane a pid))
    (define sync (pane-sync p))
    (cond
      [(not sync) a]
      [else
       (define-values (doc st cur) (sync (make-ctx a pid) (pane-state p)))
       (define a1 (app-set-pane a pid (struct-copy pane p [state st])))
       (cond
         [(not doc) a1]
         [else
          (editor-view-assign! (app-editor a1) (pane-vid p) doc)
          (when cur (editor-view-set-point! (app-editor a1) (pane-vid p) cur))
          a1])])))

;; 输入 → 命中 pane（鼠标）或焦点 pane（键盘）→ state + effects → 解释 effects。
(define (dispatch a in)
  (cond
    [(pointer? in)
     (define pid (layout-hit (app-layout a) (app-cols a) (app-rows a)
                             (pointer-row in) (pointer-col in)))
     (cond
       [(not pid) a]
       [else
        (define p (app-pane a pid))
        (define a1 (if (pane-focusable? p) (focus-set a pid) a))
        (define f (pane-pointer p))
        (cond
          [(not f) a1]
          [else
           (define r (app-pane-rect a1 pid))
           (define-values (st eff)
             (f (make-ctx a1 pid) (pane-state p) in
                (- (pointer-row in) (lrect-y r))
                (- (pointer-col in) (lrect-x r))))
           (apply-effects (app-set-pane a1 pid (struct-copy pane p [state st])) eff)])])]
    [else
     (define pid (app-focus a))
     (define p (app-pane a pid))
     (define f (pane-input p))
     (cond
       [(not f) a]
       [else
        (define-values (st eff) (f (make-ctx a pid) (pane-state p) in))
        (apply-effects (app-set-pane a pid (struct-copy pane p [state st])) eff)])]))

;;; ---------- effects ----------

;; effect = 会动全局结构的动作。组件只描述，本模块执行。
;;   (list 'open path)
;;   (list 'close-document did)
;;   (list 'close-view vid)
;;   (list 'new-view did point)
;;   (list 'show-view pid vid)
;;   (list 'focus pid)
;;   (list 'focus-view vid)
;;   (list 'save pid)
;;   (list 'split dir)          ; dir = 'h | 'v
;;   (list 'close-pane pid)
;;   (list 'resize-focus delta)
;;   (list 'quit)

(define (apply-effects a effs)
  (for/fold ([a a]) ([e (in-list effs)]) (apply-effect a e)))

(define (apply-effect a e)
  (match e
    [(list 'open path)            (app-open a path)]
    [(list 'close-document did)   (app-close a did)]
    [(list 'close-view vid)       (app-close-view a vid)]
    [(list 'new-view did point)   (app-new-view a did point)]
    [(list 'show-view pid vid)    (app-show-view a pid vid)]
    [(list 'focus pid)            (focus-set a pid)]
    [(list 'focus-view vid)       (app-focus-view a vid)]
    [(list 'save pid)             (app-save a pid)]
    [(list 'split dir)            (layout-split! a dir)]
    [(list 'close-pane pid)       (if (= pid (app-focus a)) (layout-close! a) a)]
    [(list 'resize-focus delta)   (editor-resize-focus a delta)]
    [(list 'quit)                 (quit-request a)]
    [else a]))

;;; ============================================================================
;;; 测试（文档管理 / 焦点 / 布局 / 退出 / 视图）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/text/document.rkt")

  (define d (make-temporary-file "rbst-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  ;; 三个 pane：0 树 / 1 编辑格 / 2 状态栏（组件逻辑用 #f 代替，只测全局状态）
  (define ed0 (editor-open "" 10 5 #:line-numbers? #t))
  (define-values (ed1 _tdid tvid) (editor-add-document-view ed0 "" 10 4 "*tree*" #:line-numbers? #f))
  (define-values (ed2 _sdid svid) (editor-add-document-view ed1 "" 40 1 "*status*" #:line-numbers? #f))
  (define panes (hash 0 (pane 'tree tvid #f #f #f #t #f)
                      1 (pane 'buffer 0 #f #f #f #t #f)
                      2 (pane 'status svid #f #f #f #f #f)))
  (define a (app ed2 (hash) panes (vsplit-bottom 1 (hsplit-left 30 (lpane 0) (lpane 1) 1) (lpane 2))
                 0 1 5 40 #f #f '()))

  ;; 文档管理：打开 / 显示 / 保存 / 关闭
  (define a1 (app-open a f))
  (check-equal? (editor-view-string (app-editor a1) (app-pane-vid a1 1)) "hello\nworld\n")
  (define-values (_c-a1 _o-a1) (editor-view-insert! (app-editor a1) (app-pane-vid a1 1) "X"))
  (define a3 (app-save a1 1))
  (check-equal? (file->string f) "Xhello\nworld\n")
  (define a4 (app-close a3 (hash-ref (app-opened a3) f)))
  (check-false (hash-has-key? (app-opened a4) f))
  (check-equal? (editor-view-string (app-editor a4) (app-pane-vid a4 1)) "")
  (check-equal? (length (editor-documents (app-editor (app-open a4 (build-path d "nope")))))
                (length (editor-documents (app-editor a4))))

  ;; 焦点循环（初始焦点 0）
  (check-equal? (app-focus (focus-next! a4)) 1)     ; 0 → 1
  (check-equal? (app-focus (focus-prev! a4)) 1)     ; 0 → 1（回绕）

  ;; 分格 / 关格
  (define as (layout-split! (focus-set a4 1) 'h))
  (check-true (hash-has-key? (app-panes as) 3))
  (check-equal? (app-focus as) 3)
  (check-equal? (app-focus (focus-direction! as 'left)) 1)
  (define ac (layout-close! (focus-set as 1)))
  (check-false (hash-has-key? (app-panes ac) 1))

  ;; 调宽（焦点 pane 宽度）
  (check-equal? (lrect-w (app-pane-rect (editor-resize-focus a 5) 0)) 35)   ; 树在左 → 变宽
  (check-equal? (lrect-w (app-pane-rect (editor-resize-focus a -5) 0)) 25)

  ;; 退出：逐个问未保存文档
  (define g (build-path d "b.txt"))
  (display-to-file "b\n" g #:exists 'replace)
  (define b1 (app-open a f))                                    ; 打开 f
  (define-values (_c-b1 _o-b1) (editor-view-insert! (app-editor b1) (app-pane-vid b1 1) "X"))
  (define b2 (app-open b1 g))     ; 打开 g（f 已脏）
  (define-values (_c-b2 _o-b2) (editor-view-insert! (app-editor b2) (app-pane-vid b2 1) "Y"))
  (define b3 b2)
  (define q1 (quit-request b3))
  (check-false (app-quit? q1))
  (check-true (and (app-quit-ask q1) #t))
  (define q2 (quit-save-current q1))                            ; 保存第一个
  (define q3 (quit-save-current q2))                            ; 保存第二个 → 退出
  (check-true (app-quit? q3))
  (check-equal? (file->string f) "XXhello\nworld\n")
  (check-equal? (file->string g) "Yb\n")
  ;; Esc 取消（先把当前文档再改脏）
  (define-values (_c-b3 _o-b3) (editor-view-insert! (app-editor b3) (app-pane-vid b3 1) "Z"))
  (define b4 b3)
  (define q4 (quit-request b4))
  (check-true (and (app-quit-ask q4) #t))
  (check-false (app-quit-ask (quit-cancel q4)))
  ;; 不脏 → 直接退出
  (check-true (app-quit? (quit-request a)))

  ;; ---------- 视图管理（一个文档多个视图） ----------
  (define m0 (editor-open "" 10 4 #:line-numbers? #t))
  (define-values (m1 _mdid mtv) (editor-add-document-view m0 "" 8 4 "*tree*" #:line-numbers? #f))
  (define panes* (hash 0 (pane 'tree mtv #f #f #f #t #f)
                       1 (pane 'buffer 0 #f #f #f #t #f)))
  (define va (app m1 (hash) panes* (hsplit-left 8 (lpane 0) (lpane 1) 1)
                 1 1 4 30 #f #f '()))
  ;; 打开 f：空占位 scratch 被丢掉，f 拿到一个视图（不残留 *scratch*）
  (define vb (app-open va f))
  (check-equal? (length (app-open-views vb)) 1)
  (define fdid (editor-view-document-id (app-editor vb) (app-pane-vid vb 1)))
  ;; 再打开同一文件：复用同一视图（不新增）
  (define vc (app-open vb f))
  (check-equal? (length (app-open-views vc)) 1)
  (check-equal? (app-pane-vid vc 1) (app-pane-vid vb 1))
  ;; 手动加第二个视图（未显示）
  (define-values (med2 v2) (editor-add-view (app-editor vc) fdid 20 4 'free #f #:line-numbers? #t))
  (define vd (struct-copy app vc [editor med2]))
  (check-equal? (length (app-open-views vd)) 2)
  ;; 让 pane1 显示 v2（未显示 → 可切换）；旧视图仍在
  (define ve (app-show-view vd 1 v2))
  (check-equal? (app-pane-vid ve 1) v2)
  (check-equal? (length (app-open-views ve)) 2)
  ;; 已在别的 pane 显示的视图：app-show-view 不动 pane（由调用方聚焦）
  (define vx (app-show-view ve 1 v2))
  (check-equal? (app-pane-of-view vx v2) 1)
  ;; app-focus-view：显示并聚焦
  (check-equal? (app-focus (app-focus-view vd v2)) 1)
  ;; 关一个视图：文档还有另一个视图 → 文档保留
  (define vf (app-close-view ve (app-pane-vid vb 1)))
  (check-equal? (length (app-open-views vf)) 1)
  (check-true (hash-has-key? (app-opened vf) f))
  ;; 关最后一个视图：文档一起关、opened 移除
  (define vg (app-close-view vf (app-pane-vid vf 1)))
  (check-false (hash-has-key? (app-opened vg) f))

  ;; effect 解释：open + focus 一步到位
  (define ae (apply-effects vd (list (list 'focus 1) (list 'open f))))
  (check-equal? (app-focus ae) 1)
  (check-true (hash-has-key? (app-opened ae) f))

  (delete-directory/files d)
  (displayln "lab/state.rkt: all tests passed"))
