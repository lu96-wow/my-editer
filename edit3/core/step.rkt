#lang racket

;;; edit3/step.rkt —— 状态转移（纯）+ 应用装配 + 路由
;;;
;;;   step : State Size Event -> State + [Effect]
;;;   jobs : State -> [Job]
;;;
;;; 由 edit2 平移：路由/原语/输入行/区域/文件/面板，全部改走 edit3 的
;;; tiling + floats + window 抽象；指针拖拽仍走 interaction.rkt。
;;; 路由分三层，按顺序：全局 → 面板（树/缓冲区）→ 编辑（焦点是编辑器时）。

(provide step boot jobs app-routes
         refresh-panels!
         input-name
         doc-keys bind-doc-keys focused-keymap apply-doc-keys add-doc-keys
         wid-vid wid-panel-name editor-wids panel-wid
         region-visible-vid region-visible? region-active
         focused-did set-focused-path!)

(require racket/string
         "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "command.rkt" "keymap.rkt" "op.rkt" "prompt.rkt"
         "adapter.rkt" "layout.rkt" "resize.rkt" "window.rkt" "interaction.rkt"
         "border.rkt" "panels.rkt" "fs.rkt" "mode.rkt" "plugin.rkt" "hook.rkt" "face-plugin.rkt"
         "../plugins/catalog.rkt"
         (rename-in "../config/app.rkt"
                    [regions regions-spec]
                    [enabled-panels panels-spec]
                    [key-tables key-tables-spec]
                    [float-specs float-specs-spec]
                    [doc-key-matchers doc-key-matchers-spec]
                    [border-style border-style-spec]
                    [borders-on? borders-default?])
         (rename-in "../config/plugins.rkt"
                    [enabled-plugins enabled-plugin-specs]))

;; 新窗口默认边框（#f = 不加）；可用 C-t 逐个切换。
(define default-border (and borders-default? border-style-spec))

;; 基础（未被插件叠加前）配置：区域 / 键表 / 文档匹配层。
(define base-regions (map parse-region regions-spec))
(define base-key-table (compose-keymaps key-tables-spec))
(define (state-regions st) (feature-ref st 'regions base-regions))
(define (state-doc-matchers st) (feature-ref st 'doc-key-matchers doc-key-matchers-spec))
(define (state-routes st) (feature-ref st 'routes #f))

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

;;; ---------- 正在输入的命令序列 ----------

(define (key-seq st) (feature-ref st 'keys '()))
(define (key-seq-push st label)
  (if label (feature-set st 'keys (append (key-seq st) (list label))) st))
(define (key-seq-clear st) (feature-set st 'keys '()))
(define (prefix-enter-op? o) (memq (car o) '(prefix-new prefix-split)))

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

;;; ---------- 作用域 ----------

(define (panel-name-of x) (if (symbol? x) (format "*~a*" x) x))

(define (scope-of s)
  (define base
    (cond
      [(eq? s 'always) always]
      [(eq? s 'editor) editor-focus?]
      [(eq? s 'float)  (lambda (st ev) (and (wid-float? st (state-focus st)) #t))]
      [(eq? s 'prompt) (lambda (st ev) (and (prompt-of st) #t))]
      [(eq? s 'new)  (lambda (st ev) (eq? (prefix-of st) 'new))]
      [(eq? s 'new2) (lambda (st ev) (eq? (prefix-of st) 'new2))]
      [(eq? s 'split) (lambda (st ev) (eq? (prefix-of st) 'split))]
      [(eq? s 'placing) (lambda (st ev) (and (placing-of st) #t))]
      [(and (pair? s) (eq? (car s) 'panel)) (focus-panel? (panel-name-of (cadr s)))]
      [(and (pair? s) (eq? (car s) 'region))
       (lambda (st ev) (and (member (wid-panel-name st (state-focus st)) (region-members* st (cadr s))) #t))]
      [else always]))
  (cond
    [(eq? s 'prompt) base]
    [else (lambda (st ev) (and (not (prompt-of st)) (base st ev)))]))

;;; ---------- op 解释器 ----------

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
    [(and (pair? target) (eq? (car target) 'panel)) (values (focus-panel! st (panel-name-of (cadr target))) '())]
    [(and (pair? target) (eq? (car target) 'cycle)) (values (focus-cycle st (cadr target)) '())]
    [else (values st '())]))

(define base-op-registry
  (make-op-registry
   (list
    (cons 'insert            (lambda (ctx st ev args) (insert-text st (car args))))
    (cons 'insert-event-text (lambda (ctx st ev args) (insert-text st (text-event-text ev))))
    (cons 'delete-back       (lambda (ctx st ev args) (edit-focused st 'backspace)))
    (cons 'delete            (lambda (ctx st ev args) (edit-focused st 'delete)))
    (cons 'move              (lambda (ctx st ev args) (nav-focused st (car args) (and (pair? (cdr args)) (cadr args)))))
    (cons 'undo              (lambda (ctx st ev args) (edit-focused st 'undo)))
    (cons 'redo              (lambda (ctx st ev args) (edit-focused st 'redo)))
    (cons 'select-all        (lambda (ctx st ev args) (edit-focused st 'select-all)))
    (cons 'copy              (lambda (ctx st ev args) (edit-focused st 'copy)))
    (cons 'cut               (lambda (ctx st ev args) (edit-focused st 'cut)))
    (cons 'paste             (lambda (ctx st ev args) (edit-focused st 'paste)))
    (cons 'split             (lambda (ctx st ev args)
                               (let-values ([(ax first?) (split-spec (if (pair? args) (car args) 'h))])
                                 (values (split-focused st ax first?) '()))))
    (cons 'place-confirm     (lambda (ctx st ev args) (place-confirm st)))
    (cons 'place-cancel      (lambda (ctx st ev args) (place-cancel st)))
    (cons 'place-cycle       (lambda (ctx st ev args) (values (place-cycle st (car args)) '())))
    (cons 'place-pick        (lambda (ctx st ev args) (place-pick ctx st ev)))
    (cons 'close-window      (lambda (ctx st ev args) (values (close-window! st (state-focus st)) '())))
    (cons 'close-view        (lambda (ctx st ev args) (values (close-view-at-focus! st) '())))
    (cons 'close-doc         (lambda (ctx st ev args) (request-close-doc-at-focus st)))
    (cons 'save              (lambda (ctx st ev args) (save-focused st)))
    (cons 'quit              (lambda (ctx st ev args) (request-quit st)))
    (cons 'pointer           (lambda (ctx st ev args) (values (cursor-press ctx st ev) '())))
    (cons 'pointer-move      (lambda (ctx st ev args) (values (pointer-move (ctx-geometry ctx) st ev) '())))
    (cons 'pointer-release   (lambda (ctx st ev args) (values (pointer-release st ev) '())))
    (cons 'scroll            (lambda (ctx st ev args) (cursor-scroll ctx st ev (car args))))
    (cons 'region-toggle     (lambda (ctx st ev args) (values (region-toggle! st (car args)) '())))
    (cons 'region-show       (lambda (ctx st ev args) (values (region-show! st (car args)) '())))
    (cons 'region-hide       (lambda (ctx st ev args) (values (region-hide! st (car args)) '())))
    (cons 'region-activate   (lambda (ctx st ev args) (values (region-activate! st (car args) (panel-doc-name (cadr args))) '())))
    (cons 'region-cycle      (lambda (ctx st ev args) (values (region-cycle! st (car args) (cadr args)) '())))
    (cons 'region-focus      (lambda (ctx st ev args) (values (region-focus! st (car args)) '())))
    (cons 'focus             (lambda (ctx st ev args) (run-focus-op st (car args))))
    (cons 'float-open        (lambda (ctx st ev args) (values (float-open-named st (car args)) '())))
    (cons 'float-close       (lambda (ctx st ev args)
                               (define w (state-focus st))
                               (values (if (and w (wid-float? st w)) (close-float st w) st) '())))
    (cons 'float-toggle      (lambda (ctx st ev args)
                               (define name (car args))
                               (define v (view-of-name st (format "*~a*" name)))
                               (cond
                                 [(not v) (values st '())]
                                 [else
                                  (define fw (float-wid-of-vid st v))
                                  (values (if fw (close-float st fw) (float-open-named st name)) '())])))
    (cons 'float-cycle       (lambda (ctx st ev args) (values (cycle-float st) '())))
    (cons 'float-raise       (lambda (ctx st ev args)
                               (define w (state-focus st))
                               (values (if (and w (wid-float? st w)) (raise-float st w) st) '())))
    (cons 'activate          (lambda (ctx st ev args) (activate-focused st)))
    (cons 'collapse          (lambda (ctx st ev args) (tree-collapse st)))
    (cons 'tree-parent       (lambda (ctx st ev args) (tree-move-parent st)))
    (cons 'tree-child        (lambda (ctx st ev args) (tree-move-child st)))
    (cons 'tree-new-file     (lambda (ctx st ev args) (tree-new-file st)))
    (cons 'tree-new-dir      (lambda (ctx st ev args) (tree-new-dir st)))
    (cons 'tree-delete       (lambda (ctx st ev args) (tree-delete st)))
    (cons 'tree-reload       (lambda (ctx st ev args) (values (tree-reload st) '())))
    (cons 'tree-toggle-hidden (lambda (ctx st ev args) (values (tree-hidden-toggle st) '())))
    (cons 'prefix-new        (lambda (ctx st ev args) (values (prefix-new st) '())))
    (cons 'prefix-split      (lambda (ctx st ev args) (values (prefix-set st 'split) '())))
    (cons 'prefix-cancel     (lambda (ctx st ev args) (values (prefix-cancel st) '())))
    (cons 'submit-prompt     (lambda (ctx st ev args) (submit-prompt base-prompt-kinds st)))
    (cons 'cancel-prompt     (lambda (ctx st ev args) (cancel-prompt st)))
    (cons 'buffers-toggle    (lambda (ctx st ev args) (values (buffers-toggle st) '())))
    (cons 'buffers-expand    (lambda (ctx st ev args) (values (buffers-fold! st #f) '())))
    (cons 'buffers-collapse  (lambda (ctx st ev args) (values (buffers-fold! st #t) '())))
    (cons 'new-view          (lambda (ctx st ev args) (values (new-view-for-focused st) '())))
    (cons 'border-toggle     (lambda (ctx st ev args) (values (border-toggle st) '()))))))

(define (placing-op-seq? ops)
  (for/or ([o (in-list ops)]) (memq (car o) '(place-confirm place-cancel place-cycle place-pick))))

(define (prefix-op-seq? ops)
  (for/or ([o (in-list ops)])
    (memq (car o) '(prefix-new prefix-split prefix-cancel tree-new-file tree-new-dir))))

(define (run-ops reg ctx st ev ops)
  (define st0
    (cond
      [(and (placing-of st) (not (placing-op-seq? ops))) (cancel-placing st)]
      [(and (prefix-of st) (not (prefix-op-seq? ops))) (prefix-cancel st)]
      [else st]))
  (define-values (st1 effs)
    (for/fold ([st st0] [effs '()]) ([o (in-list ops)])
      (define-values (st* e*) (op-run reg ctx st ev o))
      (values st* (append effs e*))))
  (values (if (and (prefix-of st1) (not (for/or ([o (in-list ops)]) (prefix-enter-op? o))))
              (prefix-cancel st1)
              st1)
          effs))

(define (op-runner reg binding ops)
  (lambda (ctx st ev k)
    (define-values (st* effs) (run-ops reg ctx (key-seq-push st (binding-label binding)) ev ops))
    (values (if (prefix-of st*) st* (key-seq-clear st*)) effs)))

;;; ---------- 路由 ----------

(define (app-routes [reg base-op-registry] [prompts base-prompt-kinds] [kt base-key-table])
  (define reg* (op-register reg 'submit-prompt (lambda (ctx st ev args) (submit-prompt prompts st))))
  (define runner (lambda (binding ops) (op-runner reg* binding ops)))
  (define global (compile-routes kt scope-of runner))
  (define doc-route
    (route (lambda (st ev) (and (focused-keymap st) #t))
           (lambda (ctx st ev k)
             (route-input/k (compile-routes (focused-keymap st) scope-of runner)
                            ctx st ev k))))
  (cons doc-route global))

;;; ---------- 后台需求 ----------

(define (jobs st) '())

;;; ---------- 入口 ----------

(define (step st size ev)
  (cond
    [(resize-event? ev) (values st '())]
    [(job-event? ev) (values st '())]
    [else
     (define g (layout (state-tiling st) (state-floats st) size))
     (define f0 (state-focus st))
     (define-values (st* effs)
       (route-input (or (state-routes st) (app-routes)) (ctx size g) st ev))
     (if (eqv? f0 (state-focus st*))
         (values st* effs)
         (values (emit st* 'focus-changed (list (state-focus st*) f0)) effs))]))

;;; ---------- 装配 ----------

;; 把插件贡献叠加到基础表上，得到本次运行的 op / prompt / panel / region / 键表 / 匹配层，
;; 并编译路由存进 State（step 从 State 读，不依赖插件）。
(define (boot w h #:text [text ""] #:name [name #f]
                   #:root [root (current-directory)]
                   #:plugins [plugins (plugins-by-names enabled-plugin-specs)])
  (define reg (install-plugin-ops base-op-registry plugins))
  (define prompts (install-plugin-prompts base-prompt-kinds plugins))
  (define panel-reg (install-plugin-panels base-panel-registry plugins))
  (define region-list (install-plugin-regions base-regions plugins))
  (define kt (append (append* (collect-key-tables plugins))
                     (compose-keymaps key-tables-spec)))
  (define matchers (append doc-key-matchers-spec (collect-doc-key-matchers plugins)))
  ;; 核心钩子：编辑 / 移动光标后刷新 face（这样插件接管的按键也能刷新）。
  (define core-hooks
    (list (reaction* 'after-edit   (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))
          (reaction* 'after-insert (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))
          (reaction* 'after-nav    (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))))
  (define hooks (append core-hooks (collect-hooks plugins)))
  (define faces (collect-faces plugins))
  (define routes (app-routes reg prompts kt))
  (define ed0 (blank-editor))
  (define-values (ed1 did vid)
    (if name
        (add-document-view! ed0 text w (max 1 (- h 1)) name)
        (values ed0 #f #f)))
  ;; 为**所有已注册面板**各建一个文档（含插件面板）。
  (define-values (ed2 vids)
    (for/fold ([ed ed1] [vids (hash)]) ([nm (in-list (panel-names panel-reg))])
      (define-values (ed* _pdid vid*) (add-panel! ed "" w 1 nm))
      (values ed* (hash-set vids nm vid*))))
  (define docs
    (for/fold ([d (if did
                      (hash did (doc-meta #f (document-handle ed2 did)))
                      (hash))])
              ([(nm v) (in-hash vids)])
      (hash-set d (view-did ed2 v) (doc-meta #f #f))))
  ;; 底盘：侧栏（区域 sidebar，贴根）+ 主区（编辑器 / 状态栏）。
  (define tree-vid (hash-ref vids "*tree*"))
  (define status-vid (hash-ref vids "*status*"))
  (define right (split 'v (list (item 1 1 1 2 (editor-tile 0 vid default-border))          ; 编辑区 flex（min 2）
                                (item 1 0 0 1 (panel-tile 1 status-vid default-border)))))  ; 状态栏 1 行
  (define base (split 'h (list (item 28 0 0 1 (panel-tile 2 tree-vid default-border))        ; 侧栏固定 28 列
                               (item 1 1 1 2 right))))
  (define st0 (make-state #:ed ed2 #:docs docs #:tiling (tiling base) #:focus 0))
  (define st1 (feature-set st0 'panels panel-reg))
  (define st2 (feature-set st1 'regions region-list))
  (define st3 (feature-set st2 'doc-key-matchers matchers))
  (define st4 (feature-set st3 'routes routes))
  (define st5 (feature-set st4 'plugins plugins))
  (define st5b (feature-set st5 'hooks hooks))
  (define st5c (feature-set st5b 'faces faces))
  (define st6 (run-plugin-boots st5c plugins))
  (define st7 (feature-set st6 'tree (tree-init root)))
  (define st8 (region-set-active st7 'sidebar "*tree*"))
  (region-set-active st8 'log "*log*"))
