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
         region-visible-vid region-visible? region-active
         region-toggle! region-show! region-hide! region-activate! region-cycle! region-focus!)

(require racket/string
         "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "command.rkt" "adapter.rkt" "layout.rkt"
         "panels.rkt" "fs.rkt"
         (rename-in "../config/app.rkt"
                    [regions regions-spec]
                    [frame frame-spec]
                    [enabled-panels panels-spec]))

;; 配置数据 → region 结构（成员映射到文档名）。
(define regions (map parse-region regions-spec))

;;; ---------- 查询辅助 ----------

(define (view-of-name st name)
  (define ed (state-ed st))
  (for/first ([vid (in-list (view-id-list ed))]
              #:when (equal? name (view-document-name ed vid)))
    vid))

(define (focused-did st)
  (define v (state-focus st))
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
  (and (state-focus st) (not (panel-name st (state-focus st)))))

(define ((focus-panel? name) st ev)
  (equal? name (panel-name st (state-focus st))))

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
  (define v (state-focus st))
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
  (define v (state-focus st))
  (cond
    [(not v) (values st '())]
    [else (insert! (state-ed st) v text) (values st '())]))

(define ((nav-handler dir shift?) st ev)
  (define v (state-focus st))
  (cond
    [(not v) (values st '())]
    [else (nav! (state-ed st) v dir shift?) (values st '())]))

(define (doc-display st did)
  (define m (hash-ref (state-docs st) did #f))
  (cond [(and m (doc-meta-path m)) (format "~a" (doc-meta-path m))]
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

(define (center-vid st)
  (for/first ([vid (in-list (layout-vids (state-layout st)))]
              #:when (not (panel-name st vid)))
    vid))

(define (split-focused st axis)
  (define v (state-focus st))
  (define did (and v (view-did (state-ed st) v)))
  (cond
    [(not did) st]
    [else
     (define-values (ed* nvid) (add-view! (state-ed st) did 40 10))
     (struct-copy state st
                  [ed ed*]
                  [layout (layout-split-pane (state-layout st) v axis nvid)]
                  [focus nvid])]))

(define (place-view st vid)
  (define center (center-vid st))
  (define l (state-layout st))
  (struct-copy state st
               [layout (cond [center (layout-replace l center vid)]
                             [(layout-has-empty? l) (layout-fill-empty l (pane vid))]
                             [(blank? l) (pane vid)]
                             [else (layout-add-side l (pane vid) 'left 0)])]
               [focus vid]))

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

;; 区域当前显示的 vid（#f = 隐藏）
(define (region-visible-vid st rid)
  (for/first ([m (in-list (region-members* rid))]
              #:when (layout-has? (state-layout st) (panel-vid st m)))
    (panel-vid st m)))

(define (region-visible? st rid) (and (region-visible-vid st rid) #t))

;; 把 pane 同步成 active 成员（不动焦点）。
(define (region-sync-pane st rid)
  (define r (region-ref rid))
  (define want (panel-vid st (region-active st rid)))
  (define cur (region-visible-vid st rid))
  (cond
    [(not want) st]
    [(not cur) (struct-copy state st
                            [layout (layout-add-main (state-layout st) (pane want)
                                                     (region-side r) (region-size r))])]
    [(eqv? cur want) st]
    [else (struct-copy state st [layout (layout-replace (state-layout st) cur want)])]))

;; 显 / 隐 / 切换（切换 = 显 ↔ 隐）
(define (region-show! st rid) (region-sync-pane st rid))

(define (region-hide! st rid)
  (define cur (region-visible-vid st rid))
  (cond
    [(not cur) st]
    [else
     (define st1 (struct-copy state st [layout (layout-remove (state-layout st) cur)]))
     ;; 隐藏了正在聚焦的成员 → 焦点回编辑器
     (if (layout-has? (state-layout st1) (state-focus st1))
         st1
         (let ([c (center-vid st1)]) (if c (struct-copy state st1 [focus c]) st1)))]))

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
  (define v (panel-vid st (region-active st rid)))
  (if v (struct-copy state st [focus v]) st))

;; 焦点在可见窗格间循环。
(define (focus-cycle st d)
  (define vids (layout-vids (state-layout st)))
  (cond
    [(null? vids) st]
    [else
     (define idx (or (for/first ([v (in-list vids)] [i (in-naturals)] #:when (eqv? v (state-focus st))) i) 0))
     (define n (modulo (+ idx d) (length vids)))
     (struct-copy state st [focus (list-ref vids n)])]))

(define (focus-editor st)
  (define v (center-vid st))
  (if v (struct-copy state st [focus v]) st))

;; 聚焦某面板（可能属于某区域）：它所在区域一并显示并置 active。
(define (focus-panel! st name)
  (define rid (for/first ([r (in-list regions)] #:when (member name (region-members r))) (region-id r)))
  (define st* (if rid (region-activate! st rid name) st))
  (define v (panel-vid st* name))
  (if v (struct-copy state st* [focus v]) st*))
;;; ---------- 关闭 / 退出（脏则数据化 prompt） ----------

(define (pick-focus st layout)
  (define vids (layout-vids layout))
  (cond [(null? vids) #f]
        [(for/first ([v (in-list vids)] #:when (not (panel-name st v))) v)]
        [else (car vids)]))

(define (focus-after st layout)
  (if (layout-has? layout (state-focus st)) (state-focus st) (pick-focus st layout)))

;; 从 layout 移除一批 vid；若这批含**全部**编辑视图，则保留一个持久空位，
;; 不让父 split 塌缩（否则状态栏会被顶到顶上）。
(define (remove-vids st layout vids)
  (define editors (filter (lambda (v) (not (panel-name st v))) vids))
  (define remaining-editors
    (for/list ([v (in-list (layout-vids layout))]
               #:unless (or (memv v vids) (panel-name st v)))
      v))
  (cond
    [(and (pair? editors) (null? remaining-editors))
     (define l1 (layout-replace-node layout (car editors) (empty-area)))
     (for/fold ([l l1]) ([v (in-list vids)] #:unless (eqv? v (car editors)))
       (layout-remove l v))]
    [else (for/fold ([l layout]) ([v (in-list vids)]) (layout-remove l v))]))

(define (close-doc! st did)
  (define ed (state-ed st))
  (define vids (document-view-list ed did))
  (define layout* (remove-vids st (state-layout st) vids))
  (struct-copy state st
               [ed (close-document ed did)]
               [docs (hash-remove (state-docs st) did)]
               [layout layout*]
               [stack (for/fold ([s (state-stack st)]) ([v (in-list vids)]) (remove v s))]
               [focus (focus-after st layout*)]))

;; 关一个视图；若它是该文档最后一个视图，则关整个文档。
(define (close-view! st vid)
  (define ed (state-ed st))
  (define did (view-did ed vid))
  (cond
    [(null? (remove vid (document-view-list ed did))) (close-doc! st did)]
    [else
     (define layout* (remove-vids st (state-layout st) (list vid)))
     (struct-copy state st
                  [ed (close-view ed vid)]
                  [layout layout*]
                  [stack (remove vid (state-stack st))]
                  [focus (focus-after st layout*)])]))

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

(define (request-close-view st vid)
  (define did (view-did (state-ed st) vid))
  (cond
    [(doc-dirty? st did)
     (values (struct-copy state st [input (prompt 'close-view
                                                  (format "save ~a? (y/n) " (doc-display st did))
                                                  "" (list vid))])
             '())]
    [else (values (close-view! st vid) '())]))

(define (set-prompt-text st t)
  (struct-copy state st [input (struct-copy prompt (state-input st) [text t])]))

(define (submit-prompt st)
  (define p (state-input st))
  (define st0 (struct-copy state st [input #f]))
  (define ans (string-downcase (string-trim (prompt-text p))))
  (case (prompt-kind p)
    [(close-view)
     (define vid (car (prompt-data p)))
     (cond
       [(member ans '("y" "yes"))
        (define-values (s effs ok?) (save-doc st0 (view-did (state-ed st0) vid)))
        (if ok?
            (values (close-view! s vid) effs)
            (values (struct-copy state st0 [input (prompt 'close-view (prompt-label p) "" (prompt-data p))]) '()))]
       [(member ans '("n" "no")) (values (close-view! st0 vid) '())]
       [else (values (struct-copy state st0 [input (prompt 'close-view (prompt-label p) "" (prompt-data p))]) '())])]
    [(quit) (handle-quit st0 ans (prompt-data p))]
    [else (values st0 '())]))

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

(define (open-file* st path)
  (cond
    [(not (fs-file? path)) (values (log-msg st (format "打不开: ~a" path)) '())]
    [else
     (define text (with-handlers ([exn:fail? (lambda (e) (format "读取失败: ~a" (exn-message e)))])
                    (fs-read-file path)))
     (define-values (ed* did vid)
       (add-document-view! (state-ed st) text 40 10 (format "~a" path)))
     (define st1 (struct-copy state st [ed ed*]))
     (define st2 (set-doc-meta st1 did (doc-meta path (document-handle ed* did))))
     (values (place-view st2 vid) '())]))

(define (buffers-enter st)
  (define items (buffer-items st))
  (define i (or (panel-line st "*buffers*") 0))
  (cond
    [(or (null? items) (>= i (length items))) (values st '())]
    [else (values (place-view st (cadr (list-ref items i))) '())]))

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

;;; ---------- 浮窗 ----------

(define (open-float st vid anchor want-w want-h)
  (struct-copy state st
               [layout (layout-add-float (state-layout st) (float vid anchor want-w want-h))]
               [stack (cons vid (remove vid (state-stack st)))]))

(define (close-float st vid)
  (struct-copy state st
               [layout (layout-remove (state-layout st) vid)]
               [stack (remove vid (state-stack st))]))

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
     (define-values (vid rx ry) (rect-local hit (cursor-event-x ev) (cursor-event-y ev)))
     (define ed (state-ed st))
     ;; 一切皆 document：面板也一样，点击 = 聚焦 + 定位到该 doc 的位置。
     (define p (screen->point ed vid (max 0 ry) (max 0 rx)))
     (when p (set-point! ed vid (car p) (cdr p)))
     (values (struct-copy state st [focus vid]) '())]))

(define (cursor-scroll ctx st ev dir)
  (define hit (layout-hit (ctx-placements ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(not hit) (values st '())]
    [else
     (define vid (placement-vid hit))
     (unless (panel-name st vid) (scroll! (state-ed st) vid (* dir 3)))
     (values st '())]))

;;; ---------- 作用域（scope 数据 → 守卫） ----------

(define (panel-name-of x) (if (symbol? x) (format "*~a*" x) x))

(define (scope-of s)
  (cond
    [(eq? s 'always) always]
    [(eq? s 'editor) editor-focus?]
    [(eq? s 'float)  (lambda (st ev) (pair? (state-stack st)))]
    [(eq? s 'prompt) (lambda (st ev) (prompt? (state-input st)))]
    [(and (pair? s) (eq? (car s) 'panel)) (focus-panel? (panel-name-of (cadr s)))]
    [(and (pair? s) (eq? (car s) 'region))
     (lambda (st ev) (and (member (panel-name st (state-focus st)) (region-members* (cadr s))) #t))]
    [else always]))

;;; ---------- op 解释器（原语） ----------

(define (nav-focused st dir extend)
  (define v (state-focus st))
  (cond [(not v) (values st '())]
        [else (nav! (state-ed st) v dir extend) (values st '())]))

(define (activate-focused st)
  (define name (panel-name st (state-focus st)))
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
    [(close-view)        (request-close-view st (state-focus st))]
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
    [else (values st '())]))

;; 一条命令 = 原语序列
(define (run-ops ctx st ev ops)
  (for/fold ([st st] [effs '()]) ([o (in-list ops)])
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
  ;; 底盘：config 的 frame 数据 → Layout（主区 + 状态栏）；区域由 region-active + show/toggle 决定。
  (define base (parse-layout frame-spec (lambda (id) (if (eq? id 'editor) vid (hash-ref vids (panel-doc-name id))))))
  (define st0 (make-state #:ed ed2 #:docs docs #:layout base #:focus vid))
  (define st1 (feature-set st0 'tree (tree-init root)))
  (define st2 (region-set-active st1 'sidebar "*tree*"))
  (define st3 (region-set-active st2 'log "*log*"))
  (region-activate! st3 'sidebar "*tree*"))

