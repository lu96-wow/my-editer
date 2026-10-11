#lang racket

;;; edit3/session.rkt —— 会话操作（纯）: 打开 / 保存 / 显示 / 分裂 / 关闭 / 脏判定 /
;;;                        区域 / 输入行 / 树 / 浮窗 / 指针
;;;
;;; 这一层是 step 与插件**共用**的领域原语：step 只负责「路由 + op 解释」，插件通过
;;; core/extension.rkt 也能直接调这些纯函数，于是 document / lifecycle / buffers 可以
;;; 做成插件，而不必把整个 step 透出。
;;;
;;; 依赖方向：session 依赖 state/layout/window/adapter/panels/plugin/hook/... 这些**基础
;;; 模块**，不依赖 step；step 依赖 session。插件依赖 extension（其再导出 session），
;;; 不会与 step 循环。

(provide
 ;; 配置值（门面 / 插件要用）
 default-border base-regions state-regions state-doc-matchers

 ;; 查询
 view-of-name wid-panel-name editor-wids panel-wid focused-did
 pick-focus focus-after main-wid editor-focus? focus-panel?

 ;; 绑定到 document 的键表
 doc-keys bind-doc-keys apply-doc-keys add-doc-keys focused-keymap
 set-doc-meta set-focused-path!

 ;; 放置选择
 placing-of place-view place-cycle place-confirm cancel-placing place-cancel place-pick

 ;; 日志
 log-msg

 ;; 编辑
 edit-focused insert-text nav-focused
 doc-display doc-dirty? save-doc save-focused save-docs

 ;; 布局手术
 center-wid split-focused split-spec

 ;; 区域代数
 region-ref region-members* region-active region-set-active
 region-visible-wid region-visible-vid region-visible?
 region-sync-pane region-show! region-hide! region-toggle!
 region-activate! region-cycle! region-focus!
 focus-cycle focus-editor focus-panel!

 ;; 关闭 / 退出
 remove-wids doc-wids vid-wids close-doc! close-window! close-view-resource!
 focus-resource close-view-at-focus! request-close-doc-at-focus
 dirty-dids ask-quit request-quit request-close-doc

 ;; 输入行
 input-name prompt-of open-prompt close-prompt prompt-answer
 submit-prompt cancel-prompt submit-with base-prompt-kinds fs-attempt handle-quit

 ;; 文件 / 缓冲区
 path-key doc-by-path open-file* show-view!
 buffers-enter buffers-current-row buffers-fold! buffers-toggle new-view-for-focused

 ;; 树
 tree-get tree-current tree-enter tree-collapse set-panel-line! tree-current-index
 tree-move-parent tree-move-child tree-target-dir tree-new-file tree-new-dir tree-delete
 tree-after-fs! tree-reload tree-hidden-toggle border-toggle

 ;; 前缀
 prefix-of prefix-set prefix-new prefix-cancel

 ;; 浮窗
 raise-float focus-wid resolve-anchor-rel float-spec
 open-float close-float cycle-float float-open-named
 run-focus-op activate-focused

 ;; 指针（需要 ctx）
 cursor-press cursor-scroll)

(require racket/string
         "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "keymap.rkt"
         "adapter.rkt" "layout.rkt" "resize.rkt" "window.rkt" "interaction.rkt"
         "panels.rkt" "fs.rkt" "mode.rkt" "prompt.rkt" "plugin.rkt" "hook.rkt" "face-plugin.rkt"
         (rename-in "../config/app.rkt"
                    [regions regions-spec]
                    [float-specs float-specs-spec]
                    [doc-key-matchers doc-key-matchers-spec]
                    [border-style border-style-spec]
                    [borders-on? borders-default?]))

;; 新窗口默认边框（#f = 不加）；可用 C-t 逐个切换。
(define default-border (and borders-default? border-style-spec))

;; 基础（未被插件叠加前）配置：区域。
(define base-regions (map parse-region regions-spec))
(define (state-regions st) (feature-ref st 'regions base-regions))
(define (state-doc-matchers st) (feature-ref st 'doc-key-matchers doc-key-matchers-spec))
;; 注意：'doc-key-matchers 的完整值由 boot 注入（含插件贡献），这里给基础默认。

;;; ---------- 查询辅助 ----------

(define (view-of-name st name)
  (define ed (state-ed st))
  (for/first ([vid (in-list (view-id-list ed))]
              #:when (equal? name (view-document-name ed vid)))
    vid))

(define (wid-panel-name st w)
  (panel-name-of-vid st (wid-vid st w)))

;; 编辑窗口 = 显示的不是面板文档的窗口。
(define (editor-wids st)
  (for/list ([w (in-list (all-wids st))]
             #:when (not (panel-name-of-vid st (wid-vid st w))))
    w))

(define (panel-wid st name)
  (wid-of-vid st (panel-vid st name)))

(define (focused-did st)
  (define v (focused-vid st))
  (and v (view-did (state-ed st) v)))

;; 焦点 / 空窗口判定。
(define (pick-focus st)
  (define ws (all-wids st))
  (cond [(null? ws) #f]
        [(for/first ([w (in-list ws)] #:when (not (panel-name-of-vid st (wid-vid st w)))) w)]
        [else (car ws)]))

(define (focus-after st)
  (if (has-wid? st (state-focus st)) (state-focus st) (pick-focus st)))

;; 「主区」= 第一个平铺编辑器窗口（区域 anchor 'main 往它旁边贴）。
(define (main-wid st)
  (for/first ([w (in-list (node-wids (tiling-root (state-tiling st))))]
              #:when (not (panel-name-of-vid st (layout-tile-vid (state-tiling st) w))))
    w))

;;; ---------- 绑定到 document 的键表 ----------

(define (doc-keys st) (feature-ref st 'doc-keys (hash)))
(define (bind-doc-keys st did table)
  (feature-set st 'doc-keys (hash-set (doc-keys st) did table)))
(define (apply-doc-keys st did path)
  (define tables (and path (matching-doc-tables path (state-doc-matchers st))))
  (cond
    [(or (not tables) (null? tables)) st]
    [else (bind-doc-keys st did (compose-keymaps tables))]))

;; 往某 did 的键表上**再叠**一张（组合：后表覆盖前表的同槽绑定）。
(define (add-doc-keys st did table)
  (define cur (hash-ref (doc-keys st) did #f))
  (bind-doc-keys st did (if cur (compose-keymaps (list cur table)) table)))

(define (focused-keymap st)
  (define d (focused-did st))
  (and d (hash-ref (doc-keys st) d #f)))

(define (set-doc-meta st did m)
  (struct-copy state st [docs (hash-set (state-docs st) did m)]))

(define (set-focused-path! st path)
  (define did (focused-did st))
  (cond
    [(not did) st]
    [else
     (define m (or (hash-ref (state-docs st) did #f) (doc-meta #f #f)))
     (define st* (apply-doc-keys (set-doc-meta st did (struct-copy doc-meta m [path path])) did path))
     (define st** (run-plugin-open st* (feature-ref st* 'plugins '()) did path))
     (refresh-faces-vid! st** (focused-vid st**))]))

(define (editor-focus? st ev)
  (and (state-focus st)
       (not (wid-panel-name st (state-focus st)))
       (not (placing-of st))))

;;; ---------- 放置选择模式 ----------

(define (placing-of st) (feature-ref st 'placing #f))

(define (place-view st vid)
  (define tiles (node-wids (tiling-root (state-tiling st))))
  (define empties (filter (lambda (w) (not (layout-tile-vid (state-tiling st) w))) tiles))
  (define editors (for/list ([w (in-list tiles)]
                             #:when (not (panel-name-of-vid st (layout-tile-vid (state-tiling st) w))))
                    w))
  (define fw (state-focus st))
  (cond
    [(pair? empties)
     (define w (if (and fw (memv fw empties)) fw (car empties)))
     (struct-copy state (set-wid-vid st w vid) [focus w])]
    [(null? editors)
     (define w (fresh-wid st))
     (struct-copy state st
                  [tiling (layout-add-side (state-tiling st) (editor-tile w vid default-border) 'right 40)]
                  [focus w])]
    [(null? (cdr editors))
     (define w (car editors))
     (struct-copy state (set-wid-vid st w vid) [focus w])]
    [else
     (define target (if (and fw (memv fw editors)) fw (car editors)))
     (feature-set (struct-copy state st [focus target])
                  'placing (placing vid (state-focus st)))]))

(define (place-cycle st d)
  (define cs (editor-wids st))
  (cond
    [(null? cs) st]
    [else
     (define i (or (for/first ([w (in-list cs)] [i (in-naturals)] #:when (eqv? w (state-focus st))) i) 0))
     (struct-copy state st [focus (list-ref cs (modulo (+ i d) (length cs)))])]))

(define (place-confirm st)
  (define p (placing-of st))
  (define es (editor-wids st))
  (define target (state-focus st))
  (cond
    [(not p) (values st '())]
    [(memv target es)
     (define st* (feature-set st 'placing #f))
     (values (struct-copy state (set-wid-vid st* target (placing-vid p)) [focus target]) '())]
    [(null? (cdr es))
     (define st* (feature-set st 'placing #f))
     (define w (car es))
     (values (struct-copy state (set-wid-vid st* w (placing-vid p)) [focus w]) '())]
    [else (values st '())]))

(define (cancel-placing st)
  (define p (placing-of st))
  (cond
    [(not p) st]
    [else
     (define st* (feature-set st 'placing #f))
     (define f (if (has-wid? st* (placing-prev-focus p))
                   (placing-prev-focus p)
                   (focus-after st*)))
     (struct-copy state st* [focus f])]))

(define (place-cancel st) (values (cancel-placing st) '()))

(define (place-pick ctx st ev)
  (define p (placing-of st))
  (define h (hit (ctx-geometry ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(or (not p) (not h)) (values st '())]
    [else
     (define w (placement-wid h))
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
     (emit st 'log-appended (list msg))]))

;;; ---------- 编辑命令 ----------

(define (edit-focused st op)
  (define v (focused-vid st))
  (cond
    [(not v) (values st '())]
    [else
     (define ed (state-ed st))
     (case op
       [(undo) (undo! ed v)] [(redo) (redo! ed v)]
       [(select-all) (select-all! ed v)]
       [(copy) (copy! ed v)] [(cut) (cut! ed v)] [(paste) (paste! ed v)]
       [(backspace) (backspace! ed v)] [(delete) (delete! ed v)])
     (values (emit st 'after-edit (list v)) '())]))

(define (insert-text st text)
  (define v (focused-vid st))
  (cond
    [(not v) (values st '())]
    [else (insert! (state-ed st) v text)
          (values (emit st 'after-insert (list v text)) '())]))

(define (nav-focused st dir extend)
  (define v (focused-vid st))
  (cond [(not v) (values st '())]
        [else (nav! (state-ed st) v dir extend)
              (values (emit st 'after-nav (list v)) '())]))

(define (doc-display st did)
  (define m (hash-ref (state-docs st) did #f))
  (cond [(and m (doc-meta-path m)) (tree-relative-path st (doc-meta-path m))]
        [else (document-name (state-ed st) did)]))

(define (doc-dirty? st did)
  (define m (hash-ref (state-docs st) did #f))
  (and m (doc-meta-saved m)
       (not (eq? (doc-meta-saved m) (document-handle (state-ed st) did)))))

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
        [else (call-with-values (lambda () (save-doc st did)) (lambda (s e _ok?) (values s e)))]))

(define (save-docs st dids)
  (for/fold ([s st] [effs '()]) ([d (in-list dids)])
    (define-values (s* e* _ok?) (save-doc s d))
    (values s* (append effs e*))))

;;; ---------- 布局手术 ----------

(define (center-wid st)
  (for/first ([w (in-list (node-wids (tiling-root (state-tiling st))))]
              #:when (not (panel-name-of-vid st (layout-tile-vid (state-tiling st) w))))
    w))

;; 分裂焦点窗口：新增一个空窗口（wid，无 vid）。
(define (split-focused st axis [first? #f])
  (define w (state-focus st))
  (cond
    [(not w) st]
    [(wid-float? st w) st]                       ; 浮窗不参与平铺分裂
    [else
     (define nwid (fresh-wid st))
     (struct-copy state st
                  [tiling (layout-split-tile (state-tiling st) w axis (editor-tile nwid #f default-border) first?)]
                  [focus nwid])]))

(define (split-spec d)
  (case d
    [(up)    (values 'v #t)]
    [(down)  (values 'v #f)]
    [(left)  (values 'h #t)]
    [(right) (values 'h #f)]
    [(v)     (values 'v #f)]
    [(h)     (values 'h #f)]
    [else    (values 'h #f)]))

;;; ---------- 区域代数 ----------

(define (region-ref st id)
  (for/first ([r (in-list (state-regions st))] #:when (eq? id (region-id r))) r))
(define (region-members* st rid) (region-members (region-ref st rid)))

(define (region-active st rid)
  (define ms (region-members* st rid))
  (define m (hash-ref (feature-ref st 'region-active (hash)) rid #f))
  (if (and m (member m ms)) m (car ms)))

(define (region-set-active st rid m)
  (feature-set st 'region-active
               (hash-set (feature-ref st 'region-active (hash)) rid m)))

;; 区域当前显示的窗口（wid）；#f = 隐藏。
(define (region-visible-wid st rid)
  (define member-vids (for/list ([m (in-list (region-members* st rid))]) (panel-vid st m)))
  (for/first ([w (in-list (all-wids st))]
              #:when (memv (wid-vid st w) member-vids))
    w))

(define (region-visible-vid st rid)
  (define w (region-visible-wid st rid))
  (and w (wid-vid st w)))

(define (region-visible? st rid) (and (region-visible-vid st rid) #t))

(define (region-sync-pane st rid)
  (define r (region-ref st rid))
  (define want (panel-vid st (region-active st rid)))
  (define cur (region-visible-wid st rid))
  (cond
    [(not want) st]
    [(not cur)
     (define w (fresh-wid st))
     (define new (panel-tile w want default-border))
     (define t*
       (cond
         [(eq? (region-anchor r) 'root)
          (layout-add-side (state-tiling st) new (region-side r) (region-size r))]
         [else
          (define target (main-wid st))
          (if target
              (layout-add-adjacent (state-tiling st) target (region-side r) (region-size r) new)
              (layout-add-side (state-tiling st) new (region-side r) (region-size r)))]))
     (struct-copy state st [tiling t*])]
    [(eqv? want (wid-vid st cur)) st]
    [else (set-wid-vid st cur want)]))

(define (region-show! st rid) (region-sync-pane st rid))

(define (region-hide! st rid)
  (define cur (region-visible-wid st rid))
  (cond
    [(not cur) st]
    [else
     (define st1 (remove-wid* st cur))
     (if (has-wid? st1 (state-focus st1))
         st1
         (struct-copy state st1 [focus (focus-after st1)]))]))

(define (region-toggle! st rid)
  (if (region-visible? st rid) (region-hide! st rid) (region-show! st rid)))

(define (region-activate! st rid m)
  (region-sync-pane (region-set-active st rid m) rid))

(define (region-cycle! st rid d)
  (define ms (region-members* st rid))
  (define idx (or (for/first ([m (in-list ms)] [i (in-naturals)]
                              #:when (equal? m (region-active st rid))) i) 0))
  (region-activate! st rid (list-ref ms (modulo (+ idx d) (length ms)))))

(define (region-focus! st rid)
  (define w (region-visible-wid st rid))
  (if w (focus-wid st w) st))

(define (focus-cycle st d)
  (cond
    [(placing-of st) (place-cycle st d)]
    [else
     (define ws (all-wids st))
     (cond
       [(null? ws) st]
       [else
        (define idx (or (for/first ([w (in-list ws)] [i (in-naturals)] #:when (eqv? w (state-focus st))) i) 0))
        (focus-wid st (list-ref ws (modulo (+ idx d) (length ws))))])]))

(define (focus-editor st)
  (define w (center-wid st))
  (if w (focus-wid st w) st))

(define (focus-panel! st name)
  (define rid (for/first ([r (in-list (state-regions st))] #:when (member name (region-members r))) (region-id r)))
  (define st* (if rid (region-activate! st rid name) st))
  (define w (panel-wid st* name))
  (if w (struct-copy state st* [focus w]) st*))

;;; ---------- 关闭 / 退出 ----------

;; 从窗口集合移除一批 wid；若这批含全部编辑窗口，则保留一个空窗口（vid = #f）。
(define (remove-wids st wids)
  (define editors (filter (lambda (w) (and (not (wid-float? st w))
                                           (not (panel-name-of-vid st (wid-vid st w))))) wids))
  (define remaining-editors
    (for/list ([w (in-list (all-wids st))]
               #:unless (or (memv w wids) (wid-float? st w)
                            (panel-name-of-vid st (wid-vid st w))))
      w))
  (cond
    [(and (pair? editors) (null? remaining-editors))
     (define keep (car editors))
     (define st1 (set-wid-vid st keep #f))
     (for/fold ([s st1]) ([w (in-list wids)] #:unless (eqv? w keep))
       (remove-wid* s w))]
    [else (for/fold ([s st]) ([w (in-list wids)]) (remove-wid* s w))]))

(define (doc-wids st did)
  (define vids (document-view-list (state-ed st) did))
  (for/list ([w (in-list (all-wids st))]
             #:when (memv (wid-vid st w) vids))
    w))

(define (vid-wids st vid)
  (for/list ([w (in-list (all-wids st))] #:when (eqv? vid (wid-vid st w))) w))

(define (close-doc! st did)
  (define ed (state-ed st))
  (define wids (doc-wids st did))
  (define st* (remove-wids st wids))
  (define st** (struct-copy state st*
                            [ed (close-document ed did)]
                            [docs (hash-remove (state-docs st*) did)]
                            [focus (focus-after st*)]))
  (emit st** 'document-closed (list did)))

(define (close-window! st wid)
  (cond
    [(not wid) st]
    [else
     (define st* (remove-wids st (list wid)))
     (struct-copy state st* [focus (focus-after st*)])]))

(define (close-view-resource! st vid)
  (cond
    [(not vid) st]
    [else
     (define wids (vid-wids st vid))
     (define st* (remove-wids st wids))
     (struct-copy state st*
                  [ed (close-view (state-ed st) vid)]
                  [focus (focus-after st*)])]))

;; 焦点 / 选中行指向的资源。→ (list did vid name) | #f
(define (focus-resource st)
  (define name (wid-panel-name st (state-focus st)))
  (cond
    [(equal? name "*buffers*")
     (define items (buffer-items st))
     (define i (or (panel-line st "*buffers*") 0))
     (and (pair? items) (< i (length items)) (list-ref items i))]
    [else
     (define v (wid-vid st (state-focus st)))
     (and v (not (panel-name-of-vid st v))
          (list (view-did (state-ed st) v) v (view-document-name (state-ed st) v)))]))

(define (close-view-at-focus! st)
  (define r (focus-resource st))
  (cond [(and r (cadr r)) (close-view-resource! st (cadr r))]
        [else st]))

(define (request-close-doc-at-focus st)
  (define r (focus-resource st))
  (cond [(and r (car r)) (request-close-doc st (car r))]
        [else (values st '())]))

(define (dirty-dids st)
  (for/list ([did (in-list (document-id-list (state-ed st)))] #:when (doc-dirty? st did)) did))

(define (ask-quit st ds)
  (cond
    [(null? ds) (values st (list (quit-effect)))]
    [else (values (open-prompt st
                               (format "save ~a? (y/n/all/nall) " (doc-display st (car ds)))
                               'quit ds)
                  '())]))

(define (request-quit st) (ask-quit st (dirty-dids st)))

(define (request-close-doc st did)
  (cond
    [(doc-dirty? st did)
     (values (open-prompt st (format "save ~a? (y/n) " (doc-display st did)) 'close-doc (list did)) '())]
    [else (values (close-doc! st did) '())]))

;;; ---------- 输入行（*input* 文档） ----------

(define input-name "*input*")

(define (prompt-of st) (feature-ref st 'prompt #f))

(define (open-prompt st label kind data)
  (define iv (panel-vid st input-name))
  (define w (or (panel-wid st "*status*") (panel-wid st input-name)))
  (cond
    [(or (not iv) (not w)) st]
    [else
     (define did (view-did (state-ed st) iv))
     (assign! (state-ed st) iv label)
     (set-point! (state-ed st) iv 0 (string-length label))
     (face-line! (state-ed st) did 0 'input)
     (readonly-range! (state-ed st) did 0 0 0 (string-length label) #t)
     ;; 状态栏那个 pane 的 vid → *input*：输入行就地占状态栏位置。
     (define st1 (feature-set st 'prompt (prompt w label kind data (state-focus st))))
     (struct-copy state (set-wid-vid st1 w iv) [focus w])]))

(define (close-prompt st)
  (define p (prompt-of st))
  (define st1 (feature-set st 'prompt #f))
  (define w (and p (prompt-wid p)))
  (define sv (panel-vid st1 "*status*"))
  (define st2 (if (and w (has-wid? st1 w) sv) (set-wid-vid st1 w sv) st1))
  (define prev (and p (prompt-prev-focus p)))
  (define f (cond [(and prev (has-wid? st2 prev)) prev]
                  [else (focus-after st2)]))
  (struct-copy state st2 [focus f]))

(define (prompt-answer st p)
  (define iv (panel-vid st input-name))
  (define full (if iv (view-string (state-ed st) iv) ""))
  (define label (prompt-label p))
  (if (>= (string-length full) (string-length label))
      (substring full (string-length label) (string-length full))
      ""))

(define (submit-prompt kinds st)
  (define p (prompt-of st))
  (cond
    [(not p) (values st '())]
    [else
     (define text (prompt-answer st p))
     (submit-with kinds (close-prompt st) p text)]))

(define (cancel-prompt st)
  (cond [(prompt-of st) (values (close-prompt st) '())]
        [else (values st '())]))

(define (submit-with kinds st p text)
  (define h (prompt-kind-lookup kinds (prompt-kind p)))
  (if h (h st p text) (values st '())))

;;; ---------- 基础 prompt kind ----------
(define base-prompt-kinds
  (make-prompt-kind-registry
   (list
    (cons 'close-doc
          (lambda (st p text)
            (define ans (string-downcase (string-trim text)))
            (define (reopen) (open-prompt st (prompt-label p) 'close-doc (prompt-data p)))
            (define did (car (prompt-data p)))
            (cond
              [(member ans '("y" "yes"))
               (define-values (s effs ok?) (save-doc st did))
               (if ok? (values (close-doc! s did) effs) (values (reopen) '()))]
              [(member ans '("n" "no")) (values (close-doc! st did) '())]
              [else (values (reopen) '())])))
    (cons 'quit
          (lambda (st p text)
            (handle-quit st (string-downcase (string-trim text)) (prompt-data p))))
    (cons 'new-file
          (lambda (st p text)
            (define d (car (prompt-data p)))
            (define nm (string-trim text))
            (cond
              [(string=? nm "") (values st '())]
              [else (fs-attempt st (lambda () (fs-make-file (build-path d nm))))
                    (values (tree-after-fs! st d) '())])))
    (cons 'new-dir
          (lambda (st p text)
            (define d (car (prompt-data p)))
            (define nm (string-trim text))
            (cond
              [(string=? nm "") (values st '())]
              [else (fs-attempt st (lambda () (fs-make-dir (build-path d nm))))
                    (values (tree-after-fs! st d) '())])))
    (cons 'delete
          (lambda (st p text)
            (define ans (string-downcase (string-trim text)))
            (cond
              [(member ans '("y" "yes"))
               (fs-attempt st (lambda () (fs-delete (car (prompt-data p)))))
               (values (tree-after-fs! st #f) '())]
              [else (values st '())]))))))

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

;;; ---------- 文件 / 缓冲区 ----------

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
          (define st* (emit (run-plugin-open st (feature-ref st 'plugins '()) did path)
                            'document-opened (list did path)))
          (define vids (document-view-list (state-ed st*) did))
          (cond
            [(pair? vids) (values (show-view! (refresh-faces-vid! st* (car vids)) (car vids)) '())]
            [else
             (define-values (ed* nvid) (add-view! (state-ed st*) did 40 10))
             (define st** (refresh-faces-vid! (struct-copy state st* [ed ed*]) nvid))
             (values (show-view! st** nvid) '())]))]
    [else
     (define text (with-handlers ([exn:fail? (lambda (e) (format "读取失败: ~a" (exn-message e)))])
                    (fs-read-file path)))
     (define-values (ed* did vid)
       (add-document-view! (state-ed st) text 40 10 (format "~a" path)))
     (define st1 (struct-copy state st [ed ed*]))
     (define st2 (set-doc-meta st1 did (doc-meta (path-key path) (document-handle ed* did))))
     (define st3 (apply-doc-keys st2 did path))
     (define st4 (run-plugin-open st3 (feature-ref st3 'plugins '()) did path))
     (define st5 (refresh-faces-vid! st4 vid))
     (values (place-view (emit st5 'document-opened (list did path)) vid) '())]))

(define (show-view! st vid)
  (define w (wid-of-vid st vid))
  (cond [w (focus-wid st w)]
        [else (place-view st vid)]))

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

(define (buffers-current-row st)
  (define rows (buffer-rows st))
  (define i (or (panel-line st "*buffers*") 0))
  (and (pair? rows) (< i (length rows)) (list-ref rows i)))

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

(define (tree-enter st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts)) (values st '())]
    [(list-ref cur 2) (values (feature-set st 'tree (tree-toggle-dir ts (car cur))) '())]
    [else (open-file* st (car cur))]))

(define (tree-collapse st)
  (define cur (tree-current st))
  (define ts (tree-get st))
  (cond
    [(or (not cur) (not ts)) (values st '())]
    [(and (list-ref cur 2) (hash-has-key? (tree-expanded ts) (car cur)))
     (values (feature-set st 'tree (tree-toggle-dir ts (car cur))) '())]
    [else (values st '())]))

(define (set-panel-line! st name i)
  (define v (panel-vid st name))
  (when v (set-point! (state-ed st) v i 0))
  st)

(define (tree-current-index st ts cur)
  (for/first ([r (in-list (tree-rows ts))] [i (in-naturals)] #:when (equal? (car cur) (car r))) i))

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
        [else (values (open-prompt st (format "新文件 ~a : " d) 'new-file (list d)) '())]))

(define (tree-new-dir st)
  (define d (tree-target-dir st))
  (cond [(not d) (values st '())]
        [else (values (open-prompt st (format "新目录 ~a : " d) 'new-dir (list d)) '())]))

(define (tree-delete st)
  (define cur (tree-current st))
  (cond
    [(not cur) (values st '())]
    [else (values (open-prompt st (format "删除 ~a ? (y/n) " (car cur)) 'delete (list (car cur))) '())]))

(define (tree-after-fs! st dir)
  (define ts0 (feature-ref st 'tree #f))
  (cond
    [(not ts0) st]
    [else (feature-set st 'tree
                        (if dir (tree-expand-dir (tree-refresh ts0) dir) (tree-refresh ts0)))]))

(define (tree-reload st) (tree-after-fs! st #f))

(define (tree-hidden-toggle st)
  (define ts0 (feature-ref st 'tree #f))
  (if ts0 (feature-set st 'tree (tree-toggle-hidden ts0)) st))

;; 焦点窗口开关边框（每个窗口独立，edit2 的 C-t 语义）。
(define (border-toggle st)
  (define w (state-focus st))
  (cond
    [(not w) st]
    [else (set-wid-border st w (and (not (wid-border st w)) border-style-spec))]))

;;; ---------- 前缀 ----------

(define (prefix-of st) (feature-ref st 'prefix #f))
(define (prefix-set st p) (feature-set st 'prefix p))
(define (prefix-new st)
  (prefix-set st (if (eq? (prefix-of st) 'new) 'new2 'new)))
(define (prefix-cancel st) (prefix-set st #f))

;;; ---------- 浮窗 ----------

(define (raise-float st wid)
  (define f (float-by-id (state-floats st) wid))
  (if f
      (struct-copy state st [floats (cons f (filter (lambda (x) (not (eqv? wid (float-wid x))))
                                                     (state-floats st)))])
      st))

(define (focus-wid st w)
  (define st1 (struct-copy state st [focus w]))
  (if (and w (wid-float? st1 w)) (raise-float st1 w) st1))

(define (resolve-anchor-rel st rel)
  (cond
    [(not rel) 'screen]
    [(eq? rel 'screen) 'screen]
    [(eq? rel 'focused) (state-focus st)]
    [(memq rel '(editor main-editor)) (center-wid st)]
    [(and (pair? rel) (eq? (car rel) 'panel)) (panel-wid st (panel-doc-name (cadr rel)))]
    [else rel]))

(define (float-spec name)
  (for/first ([s (in-list float-specs-spec)] #:when (eq? name (car s))) (cdr s)))

(define (open-float st vid anchor want-w want-h)
  (define w (fresh-wid st))
  (struct-copy state st
               [floats (cons (float w vid anchor (cons want-w want-h) default-border) (state-floats st))]
               [focus w]))

(define (close-float st wid)
  (define st1 (remove-wid* st wid))
  (if (eqv? wid (state-focus st1))
      (let ([live (map float-wid (state-floats st1))])
        (if (pair? live)
            (struct-copy state st1 [focus (car live)])
            (struct-copy state st1 [focus (focus-after st1)])))
      st1))

(define (cycle-float st)
  (define fs (state-floats st))
  (cond
    [(or (null? fs) (null? (cdr fs))) st]
    [else
     (define rotated (append (cdr fs) (list (car fs))))
     (struct-copy state st [floats rotated] [focus (float-wid (car rotated))])]))

;;; ---------- 指针 ----------

(define (cursor-press ctx st ev)
  (define g (ctx-geometry ctx))
  (define st* (pointer-press g st ev))
  (define h (hit g (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(placement? h)
     (define vid (placement-vid h))
     (define r (placement-rect h))
     (when vid
       (define p (screen->point (state-ed st*) vid
                                (max 0 (- (cursor-event-y ev) (rect-y r)))
                                (max 0 (- (cursor-event-x ev) (rect-x r)))))
       (when p (set-point! (state-ed st*) vid (car p) (cdr p)))
       (refresh-faces-vid! st* vid))
     st*]
    [else st*]))

(define (cursor-scroll ctx st ev dir)
  (define h (hit (ctx-geometry ctx) (cursor-event-x ev) (cursor-event-y ev)))
  (cond
    [(not h) (values st '())]
    [else
     (define vid (placement-vid h))
     (when (and vid (not (panel-name-of-vid st vid)))
       (scroll! (state-ed st) vid (* dir 3)))
     (values st '())]))

;;; ---------- 浮窗菜单 / 焦点 op ----------

(define (activate-focused st)
  (define name (wid-panel-name st (state-focus st)))
  (cond
    [(equal? name "*tree*")    (tree-enter st)]
    [(equal? name "*buffers*") (buffers-enter st)]
    [else (values st '())]))

(define (float-open-named st name)
  (define hv (view-of-name st (format "*~a*" name)))
  (cond
    [(not hv) st]
    [else
     (define existing (float-wid-of-vid st hv))
     (cond
       [existing (focus-wid st existing)]
       [else
        (define spec (float-spec name))
        (define a (if spec (car spec) '(anchor screen right bottom 2 2)))
        (define size (if spec (cadr spec) '(46 10)))
        (define-values (rel hh vv ddx ddy)
          (match a
            [(list 'anchor r h v dx dy) (values (resolve-anchor-rel st r) h v dx dy)]
            [_ (values 'screen 'right 'bottom 2 2)]))
        (open-float st hv (anchor rel hh vv ddx ddy) (car size) (cadr size))])]))

(define (run-focus-op st target)
  (cond
    [(eq? target 'editor) (values (focus-editor st) '())]
    [(and (pair? target) (eq? (car target) 'panel)) (values (focus-panel! st (panel-doc-name (cadr target))) '())]
    [(and (pair? target) (eq? (car target) 'cycle)) (values (focus-cycle st (cadr target)) '())]
    [else (values st '())]))
