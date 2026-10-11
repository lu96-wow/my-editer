#lang racket

;;; edit2/step.rkt —— 状态转移（纯）+ 应用装配 + 路由
;;;
;;;   step : (listof route) State Event -> State + [Effect]
;;;   jobs : State -> [Job]
;;;
;;; 路由分三层，按顺序：全局（退出/保存/开关）→ 面板（树/缓冲区）→ 编辑（焦点是编辑器时）。
;;; 编辑原语落到 core（adapter）；step 自己只做「状态 + 效果」的纯协调。

(provide step jobs app-routes boot refresh-panels! focused-did set-focused-path!
         open-float close-float cycle-float
         wid-vid wid-panel-name editor-wids panel-wid
         region-visible-vid region-visible? region-active
         region-toggle! region-show! region-hide! region-activate! region-cycle! region-focus!)

(require racket/string
         "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "command.rkt" "adapter.rkt" "layout.rkt"
         "border.rkt" "panels.rkt" "fs.rkt"
         (rename-in "../config/app.rkt"
                    [regions regions-spec]
                    [frame frame-spec]
                    [enabled-panels panels-spec]
                    [border-style border-face]
                    [borders-on? borders-default?]))

;; 默认边框 face（#f = 不加）。每个窗口可单独开关，见 border-toggle。
(define default-border (and borders-default? border-face))

;; 配置数据 → region 结构（成员映射到文档名）。
(define regions (map parse-region regions-spec))

;;; ---------- 查询辅助 ----------

(define (view-of-name st name)
  (define ed (state-ed st))
  (for/first ([vid (in-list (view-id-list ed))]
              #:when (equal? name (view-document-name ed vid)))
    vid))

;; 焦点 / 布局里的身份都是 wid；取窗口显示的 vid。
(define (wid-vid st wid)
  (and wid (layout-wid-vid (state-layout st) wid)))

(define (wid-panel-name st wid)
  (panel-name st (wid-vid st wid)))

;; 编辑窗格 = 显示的不是面板文档的窗口。
(define (editor-wids st)
  (for/list ([w (in-list (layout-wids (state-layout st)))]
             #:when (not (panel-name st (layout-wid-vid (state-layout st) w))))
    w))

(define (panel-wid st name)
  (layout-wid-of-vid (state-layout st) (panel-vid st name)))

(define (focused-did st)
  (define v (wid-vid st (state-focus st)))
  (and v (view-did (state-ed st) v)))

(define (set-doc-meta st did m)
  (struct-copy state st [docs (hash-set (state-docs st) did m)]))

(define (set-focused-path! st path)
  (define did (focused-did st))
  (cond
    [(not did) st]
    [else
     (define m (or (hash-ref (state-docs st) did #f) (doc-meta #f #f)))
     (set-doc-meta st did (struct-copy doc-meta m [path path]))]))

(define (editor-focus? st ev)
  (and (state-focus st)
       (not (wid-panel-name st (state-focus st)))
       (not (placing-of st))))

;;; ---------- 放置选择模式（打开时多窗口 → 选目标窗格） ----------

(define (placing-of st) (feature-ref st 'placing #f))

;; 把视图放上屏：先填空窗口；没有空窗口时 0 个编辑窗→新建、1 个→直接替换、
;; 多个→进选择模式，用户用鼠标/焦点选目标窗口再回车替换（焦点是 wid）。
(define (place-view st vid)
  (define l (state-layout st))
  (define es (editor-wids st))
  (define empties (filter (lambda (w) (not (layout-wid-vid l w))) es))
  (define fw (state-focus st))
  (cond
    [(pair? empties)
     (define w (if (and fw (memv fw empties)) fw (car empties)))
     (struct-copy state st [layout (layout-set-pane-vid l w vid)] [focus w])]
    [(null? es)
     (define w (layout-fresh-wid l))
     (struct-copy state st
                  [layout (cond [(layout-has-empty? l) (layout-fill-empty l (pane w vid default-border))]
                                [(blank? l) (pane w vid default-border)]
                                [else (layout-add-side l (pane w vid default-border) 'left 0)])]
                  [focus w])]
    [(null? (cdr es))
     (define w (car es))
     (struct-copy state st [layout (layout-set-pane-vid l w vid)] [focus w])]
    [else
     (define target (if (memv fw es) fw (car es)))
     (feature-set (struct-copy state st [focus target])
                  'placing (placing vid (state-focus st)))]))

;; 在当前候选窗口间循环（放置模式）。
(define (place-cycle st d)
  (define cs (editor-wids st))
  (cond
    [(null? cs) st]
    [else
     (define i (or (for/first ([w (in-list cs)] [i (in-naturals)] #:when (eqv? w (state-focus st))) i) 0))
     (struct-copy state st [focus (list-ref cs (modulo (+ i d) (length cs)))])]))

;; 回车：把待放视图换到当前候选窗口（改窗口显示的 vid，不动 wid）。
(define (place-confirm st)
  (define p (placing-of st))
  (define es (editor-wids st))
  (define target (state-focus st))
  (cond
    [(not p) (values st '())]
    [(memv target es)
     (define st* (feature-set st 'placing #f))
     (values (struct-copy state st*
                          [layout (layout-set-pane-vid (state-layout st*) target (placing-vid p))]
                          [focus target])
             '())]
    [(null? (cdr es))            ; 布局变了只剩一个：直接放它
     (define st* (feature-set st 'placing #f))
     (define w (car es))
     (values (struct-copy state st*
                          [layout (layout-set-pane-vid (state-layout st*) w (placing-vid p))]
                          [focus w])
             '())]
    [else (values st '())]))     ; 目标失效且有多个：忽略，等用户重选

;; Esc / 任何其它键：取消，恢复进入前的焦点（wid）。
(define (cancel-placing st)
  (define p (placing-of st))
  (cond
    [(not p) st]
    [else
     (define st* (feature-set st 'placing #f))
     (define f (if (layout-has-wid? (state-layout st*) (placing-prev-focus p))
                   (placing-prev-focus p)
                   (focus-after st* (state-layout st*))))
     (struct-copy state st* [focus f])]))

(define (place-cancel st) (values (cancel-placing st) '()))

;; 鼠标点候选窗口 = 选中目标。
(define (place-pick ctx st ev)
  (define p (placing-of st))
  (define hit (layout-hit (ctx-placements ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(or (not p) (not hit)) (values st '())]
    [else
     (define w (placement-wid hit))
     (cond [(memv w (editor-wids st)) (values (struct-copy state st [focus w]) '())]
           [else (values st '())])]))

(define ((focus-panel? name) st ev)
  (equal? name (wid-panel-name st (state-focus st))))

(define (log-msg st msg)
  (define lv (view-of-name st "*log*"))
  (cond
    [(not lv) st]
    [else
     (define ed (state-ed st))
     (define cur (view-string ed lv))
     (assign! ed lv (string-append cur (if (string=? cur "") "" "\n") msg))
     st]))

;;; ---------- 编辑命令 ----------

(define (edit-focused st op)
  (define v (wid-vid st (state-focus st)))
  (cond
    [(not v) (values st '())]
    [else
     (define ed (state-ed st))
     (case op
       [(undo) (undo! ed v)] [(redo) (redo! ed v)]
       [(select-all) (select-all! ed v)]
       [(copy) (copy! ed v)] [(cut) (cut! ed v)] [(paste) (paste! ed v)]
       [(backspace) (backspace! ed v)] [(delete) (delete! ed v)])
     (values st '())]))

(define (insert-text st text)
  (define v (wid-vid st (state-focus st)))
  (cond
    [(not v) (values st '())]
    [else (insert! (state-ed st) v text) (values st '())]))

(define ((nav-handler dir shift?) st ev)
  (define v (wid-vid st (state-focus st)))
  (cond
    [(not v) (values st '())]
    [else (nav! (state-ed st) v dir shift?) (values st '())]))

(define (doc-display st did)
  (define m (hash-ref (state-docs st) did #f))
  (cond [(and m (doc-meta-path m)) (tree-relative-path st (doc-meta-path m))]
        [else (document-name (state-ed st) did)]))

(define (doc-dirty? st did)
  (define m (hash-ref (state-docs st) did #f))
  (and m (doc-meta-saved m)
       (not (eq? (doc-meta-saved m) (document-handle (state-ed st) did)))))

;; 保存一个 did：写盘（effect），记存档句柄。ok? = 是否可保存。
(define (save-doc st did)
  (define m (hash-ref (state-docs st) did #f))
  (cond
    [(not (and m (doc-meta-path m)))
     (values (log-msg st (format "无文件名，无法保存: ~a" (document-name (state-ed st) did))) '() #f)]
    [else
     (define text (document-string (state-ed st) did))
     (values (set-doc-meta st did (struct-copy doc-meta m [saved (document-handle (state-ed st) did)]))
             (list (save-file (doc-meta-path m) text)) #t)]))

(define (save-focused st)
  (define did (focused-did st))
  (cond [(not did) (values st '())]
        [else (call-with-values (lambda () (save-doc st did)) (lambda (s e ok?) (values s e)))]))

(define (save-docs st dids)
  (for/fold ([s st] [effs '()]) ([d (in-list dids)])
    (define-values (s* e* _ok?) (save-doc s d))
    (values s* (append effs e*))))

;;; ---------- 布局手术 ----------

(define (center-wid st)
  (for/first ([w (in-list (layout-wids (state-layout st)))]
              #:when (not (panel-name st (layout-wid-vid (state-layout st) w))))
    w))

;; 分裂焦点窗口：新增一个**空窗口**（wid，无 vid），焦点移过去。
;; 不在新窗口显示原来的 view——留空位，然后由用户选/建视图填进去。
(define (split-focused st axis)
  (define w (state-focus st))
  (define v (wid-vid st w))
  (cond
    [(not v) st]
    [else
     (define l (state-layout st))
     (define nwid (layout-fresh-wid l))
     (struct-copy state st
                  [layout (layout-split-wid l w axis nwid #f default-border)]
                  [focus nwid])]))

;;; ---------- 区域代数（共用同一块面板的成员） ----------
;;;
;;; 一个区域 = 若干成员 + 一个 active + 显/隐。状态只有两样：
;;;   active : feature 'region-active（id -> 成员名）
;;;   显隐   : layout 里有没有 active 成员的 pane（派生，不另存）
;;;
;;; 原语只做「最小动作」，不隐式动焦点（focus 是另一个原语）。组合它们 = 行为。

(define (region-ref id)
  (for/first ([r (in-list regions)] #:when (eq? id (region-id r))) r))

(define (region-members* rid) (region-members (region-ref rid)))

;; active 成员名（缺省 = 第一个）。
(define (region-active st rid)
  (define ms (region-members* rid))
  (define m (hash-ref (feature-ref st 'region-active (hash)) rid #f))
  (if (and m (member m ms)) m (car ms)))

(define (region-set-active st rid m)
  (feature-set st 'region-active
               (hash-set (feature-ref st 'region-active (hash)) rid m)))

;; 区域当前显示的窗口（wid）；#f = 隐藏。
(define (region-visible-wid st rid)
  (define member-vids (for/list ([m (in-list (region-members* rid))]) (panel-vid st m)))
  (for/first ([w (in-list (layout-wids (state-layout st)))]
              #:when (memv (layout-wid-vid (state-layout st) w) member-vids))
    w))

;; 区域当前显示的 vid（#f = 隐藏）——对外 API。
(define (region-visible-vid st rid)
  (define w (region-visible-wid st rid))
  (and w (layout-wid-vid (state-layout st) w)))

(define (region-visible? st rid) (and (region-visible-vid st rid) #t))

;; 把该区域的窗口同步成 active 成员（不动焦点）。
(define (region-sync-pane st rid)
  (define r (region-ref rid))
  (define want (panel-vid st (region-active st rid)))
  (define cur (region-visible-wid st rid))
  (define l (state-layout st))
  (cond
    [(not want) st]
    [(not cur)
     (define w (layout-fresh-wid l))
     (struct-copy state st
                  [layout (layout-add-main l (pane w want default-border)
                                           (region-side r) (region-size r))])]
    [(eqv? want (layout-wid-vid l cur)) st]
    [else (struct-copy state st [layout (layout-set-pane-vid l cur want)])]))

;; 显 / 隐 / 切换（切换 = 显 ↔ 隐）
(define (region-show! st rid) (region-sync-pane st rid))

(define (region-hide! st rid)
  (define cur (region-visible-wid st rid))
  (cond
    [(not cur) st]
    [else
     (define st1 (struct-copy state st [layout (layout-remove-wid (state-layout st) cur)]))
     ;; 隐藏了正在聚焦的成员 → 焦点回编辑器
     (if (layout-has-wid? (state-layout st1) (state-focus st1))
         st1
         (let ([c (center-wid st1)]) (if c (struct-copy state st1 [focus c]) st1)))]))

(define (region-toggle! st rid)
  (if (region-visible? st rid) (region-hide! st rid) (region-show! st rid)))

;; 设为 active 并确保显示（不加焦点）。
(define (region-activate! st rid m)
  (region-sync-pane (region-set-active st rid m) rid))

;; 循环切换成员（显示中则换，隐藏则显示）。这就是「共用区域的切换」。
(define (region-cycle! st rid d)
  (define ms (region-members* rid))
  (define idx (or (for/first ([m (in-list ms)] [i (in-naturals)]
                              #:when (equal? m (region-active st rid))) i) 0))
  (region-activate! st rid (list-ref ms (modulo (+ idx d) (length ms)))))

;; 聚焦区域的 active 成员。
(define (region-focus! st rid)
  (define w (region-visible-wid st rid))
  (if w (struct-copy state st [focus w]) st))

;; 焦点在可见窗口间循环。
(define (focus-cycle st d)
  (cond
    [(placing-of st) (place-cycle st d)]
    [else
     (define ws (layout-wids (state-layout st)))
     (cond
       [(null? ws) st]
       [else
        (define idx (or (for/first ([w (in-list ws)] [i (in-naturals)] #:when (eqv? w (state-focus st))) i) 0))
        (define n (modulo (+ idx d) (length ws)))
        (struct-copy state st [focus (list-ref ws n)])])]))

(define (focus-editor st)
  (define w (center-wid st))
  (if w (struct-copy state st [focus w]) st))

;; 聚焦某面板（可能属于某区域）：它所在区域一并显示并置 active。
(define (focus-panel! st name)
  (define rid (for/first ([r (in-list regions)] #:when (member name (region-members r))) (region-id r)))
  (define st* (if rid (region-activate! st rid name) st))
  (define w (panel-wid st* name))
  (if w (struct-copy state st* [focus w]) st*))
;;; ---------- 关闭 / 退出（脏则数据化 prompt） ----------

(define (pick-focus st layout)
  (define ws (layout-wids layout))
  (cond [(null? ws) #f]
        [(for/first ([w (in-list ws)] #:when (not (panel-name st (layout-wid-vid layout w)))) w)]
        [else (car ws)]))

(define (focus-after st layout)
  (if (layout-has-wid? layout (state-focus st)) (state-focus st) (pick-focus st layout)))

;; 从 layout 移除一批**窗口 wid**；若这批含全部编辑窗口，则把一个换成持久空位，
;; 不让父 split 塌缩（否则状态栏会被顶到顶上）。
(define (remove-wids st layout wids)
  (define editors (filter (lambda (w) (not (panel-name st (layout-wid-vid layout w)))) wids))
  (define remaining-editors
    (for/list ([w (in-list (layout-wids layout))]
               #:unless (or (memv w wids) (panel-name st (layout-wid-vid layout w))))
      w))
  (cond
    [(and (pair? editors) (null? remaining-editors))
     ;; 保留一个空窗口（wid 不变、vid = #f），不让父 split 塌缩
     (define l1 (layout-set-pane-vid layout (car editors) #f))
     (for/fold ([l l1]) ([w (in-list wids)] #:unless (eqv? w (car editors)))
       (layout-remove-wid l w))]
    [else (for/fold ([l layout]) ([w (in-list wids)]) (layout-remove-wid l w))]))

;; 显示某 did 的所有窗口 wid。
(define (doc-wids st did)
  (define vids (document-view-list (state-ed st) did))
  (for/list ([w (in-list (layout-wids (state-layout st)))]
             #:when (memv (layout-wid-vid (state-layout st) w) vids))
    w))

;; 显示某 vid 的所有窗口 wid（同 view 多位置）。
(define (vid-wids st vid)
  (for/list ([w (in-list (layout-wids (state-layout st)))]
             #:when (eqv? vid (layout-wid-vid (state-layout st) w)))
    w))

(define (close-doc! st did)
  (define ed (state-ed st))
  (define wids (doc-wids st did))
  (define layout* (remove-wids st (state-layout st) wids))
  (struct-copy state st
               [ed (close-document ed did)]
               [docs (hash-remove (state-docs st) did)]
               [layout layout*]
               [stack (for/fold ([s (state-stack st)]) ([w (in-list wids)]) (remove w s))]
               [focus (focus-after st layout*)]))

;;; 三级资源操作：窗口 ⊂ 视图 ⊂ 文档，互不混淆。
;;;
;;;   窗口（wid）  只是 layout 里的一个展示位；摘掉它不动 core 里的资源。
;;;   视图（vid）  core 资源；关掉它不碰它的文档（哪怕这是最后一个视图）。
;;;   文档（did）  core 资源；关掉它由 core 连带关掉它全部视图。
;;;
;;; 关文档才会丢文本 → 只有关文档 / 退出需要问保存；关窗口、关视图不丢。

;; 关窗口（wid）：摘掉这个展示位，view / document 资源原样保留。
(define (close-window! st wid)
  (cond
    [(not wid) st]
    [else
     (define layout* (remove-wids st (state-layout st) (list wid)))
     (struct-copy state st
                  [layout layout*]
                  [stack (remove wid (state-stack st))]
                  [focus (focus-after st layout*)])]))

;; 关视图资源（vid）：销毁 core 的 view，并摘掉**所有**显示它的窗口；document 保留。
(define (close-view-resource! st vid)
  (cond
    [(not vid) st]
    [else
     (define wids (vid-wids st vid))
     (define layout* (remove-wids st (state-layout st) wids))
     (struct-copy state st
                  [ed (close-view (state-ed st) vid)]
                  [layout layout*]
                  [stack (for/fold ([s (state-stack st)]) ([w (in-list wids)]) (remove w s))]
                  [focus (focus-after st layout*)])]))

;; 焦点 / 选中行指向的资源。→ (list did vid name) | #f
;;   缓冲区面板：用面板 doc 的光标行（一切皆 document）选中的那一条资源；
;;   编辑器窗口：就是焦点窗口显示的视图；面板自身不当作可关资源。
(define (focus-resource st)
  (define name (wid-panel-name st (state-focus st)))
  (cond
    [(equal? name "*buffers*")
     (define items (buffer-items st))
     (define i (or (panel-line st "*buffers*") 0))
     (and (pair? items) (< i (length items)) (list-ref items i))]
    [else
     (define v (wid-vid st (state-focus st)))
     (and v (not (panel-name st v))
          (list (view-did (state-ed st) v) v (view-document-name (state-ed st) v)))]))

;; 关焦点 / 选中行的视图资源（文档保留）。
(define (close-view-at-focus! st)
  (define r (focus-resource st))
  (cond [(and r (cadr r)) (close-view-resource! st (cadr r))]
        [else st]))

;; 请关焦点 / 选中行的文档资源（连带其视图；脏则先问保存）。
(define (request-close-doc-at-focus st)
  (define r (focus-resource st))
  (cond [(and r (car r)) (request-close-doc st (car r))]
        [else (values st '())]))

(define (dirty-dids st)
  (for/list ([did (in-list (document-id-list (state-ed st)))] #:when (doc-dirty? st did)) did))

(define (ask-quit st ds)
  (cond
    [(null? ds) (values st (list (quit-effect)))]
    [else (values (struct-copy state st [input (prompt 'quit
                                                       (format "save ~a? (y/n/all/nall) " (doc-display st (car ds)))
                                                       "" ds)])
                  '())]))

(define (request-quit st) (ask-quit st (dirty-dids st)))

;; 请关一个文档资源：脏则数据化 prompt，否则直接关（core 连带其视图）。
(define (request-close-doc st did)
  (cond
    [(doc-dirty? st did)
     (values (struct-copy state st [input (prompt 'close-doc
                                                  (format "save ~a? (y/n) " (doc-display st did))
                                                  "" (list did))])
             '())]
    [else (values (close-doc! st did) '())]))

(define (set-prompt-text st t)
  (struct-copy state st [input (struct-copy prompt (state-input st) [text t])]))

(define (submit-prompt st)
  (define p (state-input st))
  (define st0 (struct-copy state st [input #f]))
  (define ans (string-downcase (string-trim (prompt-text p))))
  (case (prompt-kind p)
    [(close-doc)
     (define did (car (prompt-data p)))
     (cond
       [(member ans '("y" "yes"))
        (define-values (s effs ok?) (save-doc st0 did))
        (if ok?
            (values (close-doc! s did) effs)
            (values (struct-copy state st0 [input (prompt 'close-doc (prompt-label p) "" (prompt-data p))]) '()))]
       [(member ans '("n" "no")) (values (close-doc! st0 did) '())]
       [else (values (struct-copy state st0 [input (prompt 'close-doc (prompt-label p) "" (prompt-data p))]) '())])]
    [(quit) (handle-quit st0 ans (prompt-data p))]
    [(new-file)
     (define d (car (prompt-data p)))
     (define name (string-trim (prompt-text p)))
     (cond
       [(string=? name "") (values st0 '())]
       [else (fs-attempt st0 (lambda () (fs-make-file (build-path d name))))
             (values (tree-after-fs! st0 d) '())])]
    [(new-dir)
     (define d (car (prompt-data p)))
     (define name (string-trim (prompt-text p)))
     (cond
       [(string=? name "") (values st0 '())]
       [else (fs-attempt st0 (lambda () (fs-make-dir (build-path d name))))
             (values (tree-after-fs! st0 d) '())])]
    [(delete)
     (define path (car (prompt-data p)))
     (cond
       [(member ans '("y" "yes"))
        (fs-attempt st0 (lambda () (fs-delete path)))
        (values (tree-after-fs! st0 #f) '())]
       [else (values st0 '())])]
    [else (values st0 '())]))

;; 跑一个 fs 动作；出错记到日志，不崩。
(define (fs-attempt st thunk)
  (with-handlers ([exn:fail? (lambda (e) (log-msg st (exn-message e)))])
    (thunk)))

(define (handle-quit st ans ds)
  (define did (car ds))
  (define rest (cdr ds))
  (cond
    [(member ans '("y" "yes"))
     (define-values (s effs ok?) (save-doc st did))
     (if ok?
         (call-with-values (lambda () (ask-quit s rest))
           (lambda (s2 effs2) (values s2 (append effs effs2))))
         (values st '()))]
    [(member ans '("n" "no")) (ask-quit st rest)]
    [(member ans '("all" "a"))
     (define-values (s effs) (save-docs st (cons did rest)))
     (values s (append effs (list (quit-effect))))]
    [(member ans '("nall" "none" "!")) (values st (list (quit-effect)))]
    [else (ask-quit st ds)]))

(define (prompt-routes)
  (list
   (route (lambda (st ev) (prompt? (state-input st)))
          (handled
           (lambda (st ev)
             (define p (state-input st))
             (cond
               [(text-event? ev)
                (values (set-prompt-text st (string-append (prompt-text p) (text-event-text ev))) '())]
               [(key-is? ev 'backspace)
                (define t (prompt-text p))
                (values (set-prompt-text st (if (positive? (string-length t))
                                                (substring t 0 (sub1 (string-length t)))
                                                "")) '())]
               [(key-is? ev 'enter) (submit-prompt st)]
               [(key-is? ev 'escape) (values (struct-copy state st [input #f]) '())]
               [else (values st '())]))))))

;;; ---------- 文件 / 缓冲区打开 ----------
;; 一个 document 可对应多个 view。打开已在资源里的文件不新建 document：
;; 复用它的视图（已在布局里就聚焦，否则显示）；没有视图的孤儿文档现建一个。

(define (path-key p) (simplify-path (path->complete-path p)))

(define (doc-by-path st p)
  (define k (path-key p))
  (for/first ([did (in-list (document-id-list (state-ed st)))]
              #:when (let ([m (hash-ref (state-docs st) did #f)])
                       (and m (doc-meta-path m) (equal? k (path-key (doc-meta-path m))))))
    did))

(define (open-file* st path)
  (cond
    [(not (fs-file? path)) (values (log-msg st (format "打不开: ~a" path)) '())]
    [(doc-by-path st path)
     => (lambda (did)
          (define vids (document-view-list (state-ed st) did))
          (cond
            [(pair? vids) (values (show-view! st (car vids)) '())]
            [else
             (define-values (ed* nvid) (add-view! (state-ed st) did 40 10))
             (values (show-view! (struct-copy state st [ed ed*]) nvid) '())]))]
    [else
     (define text (with-handlers ([exn:fail? (lambda (e) (format "读取失败: ~a" (exn-message e)))])
                    (fs-read-file path)))
     (define-values (ed* did vid)
       (add-document-view! (state-ed st) text 40 10 (format "~a" path)))
     (define st1 (struct-copy state st [ed ed*]))
     (define st2 (set-doc-meta st1 did (doc-meta (path-key path) (document-handle ed* did))))
     (values (place-view st2 vid) '())]))

;; 显示一个已存在的视图：已在某个窗口就聚焦该窗口，否则放上屏。
(define (show-view! st vid)
  (define w (layout-wid-of-vid (state-layout st) vid))
  (cond [w (struct-copy state st [focus w])]
        [else (place-view st vid)]))

;; 缓冲区面板回车：
;;   view 行 → 显示/替换那个视图（多窗口则进放置模式选目标）；
;;   document 行 → 显示它第一个视图；没视图（孤儿文档）就现建一个。
(define (buffers-enter st)
  (define rows (buffer-rows st))
  (define i (or (panel-line st "*buffers*") 0))
  (cond
    [(or (null? rows) (>= i (length rows))) (values st '())]
    [else
     (define r (list-ref rows i))
     (define did (car r))
     (define vid (cadr r))
     (cond
       [(eq? (list-ref r 4) 'view) (values (show-view! st vid) '())]
       [else
        (define vids (document-view-list (state-ed st) did))
        (cond
          [(pair? vids) (values (show-view! st (car vids)) '())]
          [else
           (define-values (ed* nvid) (add-view! (state-ed st) did 40 10))
           (values (show-view! (struct-copy state st [ed ed*]) nvid) '())])])]))

;;; ---------- 资源面板折叠（document 是根） ----------

(define (buffers-current-row st)
  (define rows (buffer-rows st))
  (define i (or (panel-line st "*buffers*") 0))
  (and (pair? rows) (< i (length rows)) (list-ref rows i)))

;; v = #t 收起 / #f 展开；光标落到该 document 行。
(define (buffers-fold! st v)
  (define r (buffers-current-row st))
  (cond
    [(not r) st]
    [else
     (define did (car r))
     (define h (feature-ref st 'buffers-fold (hash)))
     (define st* (feature-set st 'buffers-fold (if v (hash-set h did #t) (hash-remove h did))))
     (define idx (for/first ([x (in-list (buffer-rows st*))] [i (in-naturals)]
                             #:when (eqv? did (car x))) i))
     (define bv (panel-vid st* "*buffers*"))
     (when bv (set-point! (state-ed st*) bv (or idx 0) 0))
     st*]))

(define (buffers-toggle st)
  (define r (buffers-current-row st))
  (cond
    [(not r) st]
    [else (define did (car r))
          (buffers-fold! st (not (hash-has-key? (feature-ref st 'buffers-fold (hash)) did)))]))

;; 给焦点窗口开关边框（每个窗口独立）。
(define (border-toggle st)
  (define w (state-focus st))
  (cond
    [(not w) st]
    [else
     (define cur (layout-wid-border (state-layout st) w))
     (struct-copy state st
                  [layout (layout-set-pane-border (state-layout st) w
                                                  (and (not cur) border-face))])]))

;; 资源面板是**唯一**能新建 view 的地方：给选中的 document 加一个未显示的 view。
(define (new-view-for-focused st)
  (define r (focus-resource st))
  (cond
    [(not (and r (car r))) st]
    [else
     (define-values (ed* _nvid) (add-view! (state-ed st) (car r) 40 10))
     (struct-copy state st [ed ed*])]))

;;; ---------- 树 ----------

(define (tree-get st)
  (define ts0 (feature-ref st 'tree #f))
  (and ts0 (tree-ensure ts0)))

(define (tree-current st)
  (define ts (tree-get st))
  (cond
    [(not ts) #f]
    [else
     (define rows (tree-rows ts))
     (define i (or (panel-line st "*tree*") 0))
     (and (pair? rows) (< i (length rows)) (list-ref rows i))]))

;; 面板导航 = 文档导航（光标行就是选择行）。
(define (panel-nav st name dir)
  (define v (panel-vid st name))
  (cond [(not v) (values st '())]
        [else (nav! (state-ed st) v dir #f) (values st '())]))

(define (tree-enter st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts)) (values st '())]
    [(list-ref cur 2)  ; 目录：展开/收起
     (values (feature-set st 'tree (tree-toggle-dir ts (car cur))) '())]
    [else (open-file* st (car cur))]))

(define (tree-collapse st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts)) (values st '())]
    [(and (list-ref cur 2) (hash-has-key? (tree-expanded ts) (car cur)))
     (values (feature-set st 'tree (tree-toggle-dir ts (car cur))) '())]
    [else (values st '())]))

;; 把某面板的光标行设到 i（一切皆 document）。
(define (set-panel-line! st name i)
  (define v (panel-vid st name))
  (when v (set-point! (state-ed st) v i 0))
  st)

;; 当前行在 rows 里的索引。
(define (tree-current-index st ts cur)
  (for/first ([r (in-list (tree-rows ts))] [i (in-naturals)] #:when (equal? (car cur) (car r))) i))

;; Left：光标移到父目录行。
(define (tree-move-parent st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts)) (values st '())]
    [else
     (define pp (tree-parent-dir (car cur)))
     (cond
       [(not pp) (values st '())]
       [else
        (define i (for/first ([r (in-list (tree-rows ts))] [i (in-naturals)]
                              #:when (equal? (explode-path pp) (explode-path (car r)))) i))
        (values (if i (set-panel-line! st "*tree*" i) st) '())])]))

;; Right：光标移到展开目录的第一个子行。
(define (tree-move-child st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts) (not (list-ref cur 2))) (values st '())]
    [else
     (define rows (tree-rows ts))
     (define i0 (tree-current-index st ts cur))
     (cond
       [(and i0 (< (add1 i0) (length rows))
             (= (list-ref (list-ref rows (add1 i0)) 3) (add1 (list-ref cur 3))))
        (values (set-panel-line! st "*tree*" (add1 i0)) '())]
       [else (values st '())])]))

;; 新建目标目录：目录行 → 该目录；文件行 → 其父目录；无选择 → 根。
(define (tree-target-dir st)
  (define ts (tree-get st))
  (define cur (tree-current st))
  (cond
    [(not ts) #f]
    [(not cur) (tree-root ts)]
    [(list-ref cur 2) (car cur)]
    [else (or (tree-parent-dir (car cur)) (tree-root ts))]))

(define (tree-new-file st)
  (define d (tree-target-dir st))
  (cond [(not d) (values st '())]
        [else (values (struct-copy state st [input (prompt 'new-file (format "新文件 ~a : " d) "" (list d))]) '())]))

(define (tree-new-dir st)
  (define d (tree-target-dir st))
  (cond [(not d) (values st '())]
        [else (values (struct-copy state st [input (prompt 'new-dir (format "新目录 ~a : " d) "" (list d))]) '())]))

(define (tree-delete st)
  (define cur (tree-current st))
  (cond
    [(not cur) (values st '())]
    [else (values (struct-copy state st [input (prompt 'delete (format "删除 ~a ? (y/n) " (car cur)) "" (list (car cur)))]) '())]))

;; 写盘变动后：重读磁盘 + 展开目标目录（只影响树）。
(define (tree-after-fs! st dir)
  (define ts0 (feature-ref st 'tree #f))
  (cond
    [(not ts0) st]
    [else (feature-set st 'tree
                        (if dir (tree-expand-dir (tree-refresh ts0) dir) (tree-refresh ts0)))]))

;; C-u：重读磁盘刷新文件树（已打开的文档不管）。
(define (tree-reload st) (tree-after-fs! st #f))

;; C-n 前缀：一次 = 新文件，两次 = 新目录。
(define (prefix-of st) (let ([i (state-input st)]) (and (memq i '(new new2)) i)))
(define (prefix-new st)
  (struct-copy state st [input (if (eq? (state-input st) 'new) 'new2 'new)]))
(define (prefix-cancel st) (struct-copy state st [input #f]))

;; 打开浮窗 = 新建一个窗口 wid 显示 vid，并压栈。
(define (open-float st vid anchor want-w want-h)
  (define l (state-layout st))
  (define w (layout-fresh-wid l))
  (struct-copy state st
               [layout (layout-add-float l (float w vid default-border anchor want-w want-h))]
               [stack (cons w (remove w (state-stack st)))]))

(define (close-float st wid)
  (struct-copy state st
               [layout (layout-remove-wid (state-layout st) wid)]
               [stack (remove wid (state-stack st))]))

(define (cycle-float st)
  (match (state-stack st)
    ['() st]
    [(list _) st]
    [(cons x rest) (struct-copy state st [stack (append rest (list x))])]))

(define (cursor-press ctx st ev)
  (define hit (layout-hit (ctx-placements ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(not hit) (values st '())]
    [else
     (define w (placement-wid hit))
     (define vid (placement-vid hit))
     (define rc (placement-rect hit))
     (define-values (bl bt _br _bb) (border-insets (state-layout st) (ctx-placements ctx) w))
     (define ed (state-ed st))
     ;; 空窗口（vid = #f）：只聚焦；有 view 才定位到内容区（边框内缩）。
     (when vid
       (define px (- (cursor-event-x ev) (rect-x rc) bl))
       (define py (- (cursor-event-y ev) (rect-y rc) bt))
       (define p (screen->point ed vid (max 0 py) (max 0 px)))
       (when p (set-point! ed vid (car p) (cdr p))))
     (values (struct-copy state st [focus w]) '())]))

(define (cursor-scroll ctx st ev dir)
  (define hit (layout-hit (ctx-placements ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(not hit) (values st '())]
    [else
     (define vid (placement-vid hit))
     (when (and vid (not (panel-name st vid)))
       (scroll! (state-ed st) vid (* dir 3)))
     (values st '())]))

;;; ---------- 作用域（scope 数据 → 守卫） ----------

(define (panel-name-of x) (if (symbol? x) (format "*~a*" x) x))

(define (scope-of s)
  (cond
    [(eq? s 'always) always]
    [(eq? s 'editor) editor-focus?]
    [(eq? s 'float)  (lambda (st ev) (pair? (state-stack st)))]
    [(eq? s 'prompt) (lambda (st ev) (prompt? (state-input st)))]
    [(eq? s 'new)  (lambda (st ev) (eq? (state-input st) 'new))]
    [(eq? s 'new2) (lambda (st ev) (eq? (state-input st) 'new2))]
    [(eq? s 'placing) (lambda (st ev) (and (placing-of st) #t))]
    [(and (pair? s) (eq? (car s) 'panel)) (focus-panel? (panel-name-of (cadr s)))]
    [(and (pair? s) (eq? (car s) 'region))
     (lambda (st ev) (and (member (wid-panel-name st (state-focus st)) (region-members* (cadr s))) #t))]
    [else always]))

;;; ---------- op 解释器（原语） ----------

(define (nav-focused st dir extend)
  (define v (wid-vid st (state-focus st)))
  (cond [(not v) (values st '())]
        [else (nav! (state-ed st) v dir extend) (values st '())]))

(define (activate-focused st)
  (define name (wid-panel-name st (state-focus st)))
  (cond
    [(equal? name "*tree*")    (tree-enter st)]
    [(equal? name "*buffers*") (buffers-enter st)]
    [else (values st '())]))

(define (float-open-named st name)
  (define hv (view-of-name st (format "*~a*" name)))
  (cond [(not hv) st]
        [else (open-float st hv (anchor #f 'right 'bottom 2 2) 46 10)]))

(define (run-focus-op st target)
  (cond
    [(eq? target 'editor) (values (focus-editor st) '())]
    [(and (pair? target) (eq? (car target) 'panel)) (values (focus-panel! st (panel-name-of (cadr target))) '())]
    [(and (pair? target) (eq? (car target) 'cycle)) (values (focus-cycle st (cadr target)) '())]
    [else (values st '())]))

;; 一条原语：ctx st event op -> (values state (listof effect))
(define (run-op ctx st ev o)
  (define tag (car o))
  (define args (cdr o))
  (case tag
    [(insert)            (insert-text st (car args))]
    [(insert-event-text) (insert-text st (text-event-text ev))]
    [(delete-back)       (edit-focused st 'backspace)]
    [(delete)            (edit-focused st 'delete)]
    [(move)              (nav-focused st (car args) (and (pair? (cdr args)) (cadr args)))]
    [(undo)              (edit-focused st 'undo)]
    [(redo)              (edit-focused st 'redo)]
    [(select-all)        (edit-focused st 'select-all)]
    [(copy)              (edit-focused st 'copy)]
    [(cut)               (edit-focused st 'cut)]
    [(paste)             (edit-focused st 'paste)]
    [(split)             (values (split-focused st editor-split-axis) '())]
    [(place-confirm)     (place-confirm st)]
    [(place-cancel)      (place-cancel st)]
    [(place-cycle)       (values (place-cycle st (car args)) '())]
    [(place-pick)        (place-pick ctx st ev)]
    [(close-window)      (values (close-window! st (state-focus st)) '())]
    [(close-view)        (values (close-view-at-focus! st) '())]
    [(close-doc)         (request-close-doc-at-focus st)]
    [(save)              (save-focused st)]
    [(quit)              (request-quit st)]
    [(pointer)           (cursor-press ctx st ev)]
    [(scroll)            (cursor-scroll ctx st ev (car args))]
    [(region-toggle)     (values (region-toggle! st (car args)) '())]
    [(region-show)       (values (region-show! st (car args)) '())]
    [(region-hide)       (values (region-hide! st (car args)) '())]
    [(region-activate)   (values (region-activate! st (car args) (panel-doc-name (cadr args))) '())]
    [(region-cycle)      (values (region-cycle! st (car args) (cadr args)) '())]
    [(region-focus)      (values (region-focus! st (car args)) '())]
    [(focus)             (run-focus-op st (car args))]
    [(float-open)        (values (float-open-named st (car args)) '())]
    [(float-close)       (values (close-float st (car (state-stack st))) '())]
    [(float-cycle)       (values (cycle-float st) '())]
    [(activate)          (activate-focused st)]
    [(collapse)          (tree-collapse st)]
    [(tree-parent)       (tree-move-parent st)]
    [(tree-child)        (tree-move-child st)]
    [(tree-new-file)     (tree-new-file st)]
    [(tree-new-dir)      (tree-new-dir st)]
    [(tree-delete)       (tree-delete st)]
    [(tree-reload)       (values (tree-reload st) '())]
    [(prefix-new)        (values (prefix-new st) '())]
    [(prefix-cancel)     (values (prefix-cancel st) '())]
    [(buffers-toggle)    (values (buffers-toggle st) '())]
    [(buffers-expand)    (values (buffers-fold! st #f) '())]
    [(buffers-collapse)  (values (buffers-fold! st #t) '())]
    [(border-toggle)     (values (border-toggle st) '())]
    [(new-view)          (values (new-view-for-focused st) '())]
    [else (values st '())]))

;; 一条命令 = 原语序列。
;; 放置模式下跑无关命令 → 先退出放置模式（瞬时模式语义）：
;; 只有自己调用 place-* 的命令不会触发退出。
(define (placing-op-seq? ops)
  (for/or ([o (in-list ops)])
    (memq (car o) '(place-confirm place-cancel place-cycle place-pick))))

(define (prefix-op-seq? ops)
  (for/or ([o (in-list ops)])
    (memq (car o) '(prefix-new prefix-cancel tree-new-file tree-new-dir))))

(define (run-ops ctx st ev ops)
  (define st0
    (cond
      [(and (placing-of st) (not (placing-op-seq? ops))) (cancel-placing st)]
      [(and (prefix-of st) (not (prefix-op-seq? ops))) (prefix-cancel st)]
      [else st]))
  (for/fold ([st st0] [effs '()]) ([o (in-list ops)])
    (define-values (st* e*) (run-op ctx st ev o))
    (values st* (append effs e*))))

(define (app-routes)
  (append (prompt-routes)
          (compile-routes key-table scope-of
                          (lambda (ops)
                            (lambda (ctx st ev k) (run-ops ctx st ev ops))))))

;;; ---------- 后台需求 ----------

(define (jobs st) '())

;;; ---------- 入口 ----------

(define (step routes ctx st ev)
  (cond
    [(resize-event? ev) (values st '())]
    [(job-event? ev) (values st '())]
    [else (route-input routes ctx st ev)]))

;;; ---------- 装配 ----------

(define (boot text name w h #:root [root (current-directory)])
  (define ed0 (blank-editor))
  (define-values (ed1 did vid) (add-document-view! ed0 text w (max 1 (- h 1)) name))
  (define-values (ed2 vids)
    (for/fold ([ed ed1] [vids (hash 'editor vid)]) ([pid (in-list panels-spec)])
      (define nm (panel-doc-name pid))
      (define-values (ed* _pdid vid*) (add-panel! ed "" w 1 nm))
      (values ed* (hash-set vids nm vid*))))
  (define help-v (hash-ref vids "*help*"))
  (assign! ed2 help-v help-text)
  (define docs
    (for/fold ([d (hash did (doc-meta #f (document-handle ed2 did)))]) ([(nm v) (in-hash vids)]
                                                                            #:unless (eq? nm 'editor))
      (hash-set d (view-did ed2 v) (doc-meta #f #f))))
  ;; 底盘：config 的 frame 数据 → Layout（主区 + 状态栏）；每个 pane 分配一个 wid。
  (define base
    (let ([n 0])
      (parse-layout frame-spec
                    (lambda (id)
                      (define v (if (eq? id 'editor) vid (hash-ref vids (panel-doc-name id))))
                      (begin0 (list n v default-border) (set! n (add1 n)))))))
  (define editor-wid (layout-wid-of-vid base vid))
  (define st0 (make-state #:ed ed2 #:docs docs #:layout base #:focus editor-wid))
  (define st1 (feature-set st0 'tree (tree-init root)))
  (define st2 (region-set-active st1 'sidebar "*tree*"))
  (define st3 (region-set-active st2 'log "*log*"))
  (region-activate! st3 'sidebar "*tree*"))

