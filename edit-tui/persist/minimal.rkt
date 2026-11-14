#lang racket

;;; edit-tui/persist/minimal.rkt —— 最小会话快照
;;;
;;; 只恢复：
;;;   · layout / areas / current-area / area-slot；
;;;   · resources（path / name / views / mode / dirty）；
;;;   · user buffer 文本 / 名字；
;;;   · user view 的光标 / 选区 / 视口。
;;;
;;; 不恢复 plugin-state / derived doc / history / session / UI 文档内容。
;;; 启动后颜色、filetree、resources、docs、workspace 全部重算。

(require (except-in racket/list range)
         racket/match
         "../core/api.rkt"
         (only-in "../../core/editor/query.rkt" view-top-line view-left-column)
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         (only-in "../core/panel/model.rkt" restore)
         "../editor/host-api.rkt"
         (only-in "../host/keymap.rkt" mode-command-stack)
         "io.rkt")

(provide snapshot-session
         restore-session!
         session-schema)

(define session-schema 1)

;;; ════════════════ 小工具 ════════════════

(define (field key alist [default #f])
  (define p (and (list? alist) (assq key alist)))
  (if p (cdr p) default))

(define (nonneg-int? x)
  (and (number? x) (exact? x) (integer? x) (>= x 0)))

(define (id-sort-key x) (format "~a" x))

(define (sorted-ids ids)
  (sort (for/list ([x (in-list ids)]) x)
        (λ (a b) (string<? (id-sort-key a) (id-sort-key b)))))

(define (point->sexpr p)
  (list (point-line p) (point-column p)))

(define (sexpr->point x)
  (match x
    [(list (? nonneg-int? l) (? nonneg-int? c)) (point l c)]
    [_ (point 0 0)]))

(define (rect->sexpr r)
  (list (rect-x r) (rect-y r) (rect-w r) (rect-h r)))

(define (sexpr->rect x)
  (match x
    [(list (? nonneg-int? x*) (? nonneg-int? y) (? nonneg-int? w) (? nonneg-int? h))
     (rect x* y w h)]
    [_ #f]))

(define (selections->sexpr sels)
  `((primary . ,(selections-primary-index sels))
    (items . ,(for/list ([s (in-list (selections-items sels))])
                `((anchor . ,(point->sexpr (selection-anchor s)))
                  (head . ,(point->sexpr (selection-head s))))))))

(define (sexpr->selections x)
  (define raw-items (let ([v (field 'items x '())]) (if (list? v) v '())))
  (define items
    (for/list ([i (in-list raw-items)])
      (selection (sexpr->point (field 'anchor i))
                 (sexpr->point (field 'head i)))))
  (define primary0 (field 'primary x 0))
  (define primary (if (nonneg-int? primary0) primary0 0))
  (if (null? items)
      (selections-one (caret (point 0 0)))
      (selections-of items primary)))

;;; ════════════════ snapshot ════════════════

(define (doc-name-of engine did)
  (define vids (engine-view-ids-for-doc engine did))
  (cond
    [(pair? vids)
     (define v (engine-view-object engine (car vids)))
     (if v (buffer-name (view-buffer v)) "")]
    [else ""]))

(define (view->sexpr engine vid)
  (define v (engine-view-object engine vid))
  `((id . ,vid)
    (doc-id . ,(engine-view-doc-id engine vid))
    (selections . ,(selections->sexpr (view-selections v)))
    (viewport . ((mode . ,(view-mode v))
                 (line-numbers? . ,(and (view-line-numbers? v) #t))
                 (top-line . ,(view-top-line v))
                 (left-column . ,(view-left-column v))
                 (anchor . ,(point->sexpr (view-anchor-point v)))))))

(define (buffer->sexpr engine did)
  `((id . ,did)
    (name . ,(doc-name-of engine did))
    (text . ,(or (engine-doc-text engine did) ""))
    (views . ,(for/list ([vid (in-list (sorted-ids
                                        (or (engine-view-ids-for-doc engine did) '())))])
                (view->sexpr engine vid)))))

(define (resource->sexpr engine root r)
  (define did (resource-doc-id r))
  `((id . ,(resource-id r))
    (doc-id . ,did)
    (path . ,(path->session root (resource-path r)))
    (name . ,(resource-name r))
    (views . ,(resource-views r))
    (mode . ,(resource-mode r))
    (dirty? . ,(and (resource-dirty? r (engine-doc-version engine did)) #t))))

(define (restore->sexpr r)
  (and r
       `((rect . ,(rect->sexpr (p:restore-rect r)))
         (parent-rect . ,(rect->sexpr (p:restore-parent-rect r))))))

(define (node->sexpr n)
  (cond
    [(not n) #f]
    [(leaf? n) `(leaf . ,(leaf-panel-id n))]
    [else
     `(split (id . ,(split-id n))
             (axis . ,(split-axis n))
             (ratio . ,(split-ratio n))
             (left . ,(node->sexpr (split-left n)))
             (right . ,(node->sexpr (split-right n))))]))

(define (panel->sexpr p)
  `((id . ,(p:panel-id p))
    (kind . ,(p:panel-kind p))
    (views . ,(p:panel-views p))
    (active . ,(p:panel-active p))
    (fixed-w . ,(p:panel-fixed-w p))
    (fixed-h . ,(p:panel-fixed-h p))
    (hidden? . ,(and (p:panel-hidden? p) #t))
    (restore . ,(restore->sexpr (p:panel-restore p)))
    (borders . ,(p:panel-borders p))
    (face . ,(p:panel-face p))
    (weight . ,(p:panel-weight p))))

(define (layout->sexpr l)
  (and l
       `((root . ,(node->sexpr (layout-root l)))
         (panels . ,(for/list ([pid (in-list (sorted-ids (layout-panel-ids l)))])
                      (panel->sexpr (layout-panel l pid))))
         (focus . ,(layout-focus l))
         (next-split-id . ,(layout-next-split-id l)))))

(define (area->sexpr a)
  `((layout . ,(layout->sexpr (editor-area-layout a)))
    (focus . ,(editor-area-focus a))))

(define (area-slot->sexpr s)
  (and s
       `((parent . ,(area-slot-parent-id s))
         (side . ,(area-slot-side s)))))

(define (snapshot-session ed state
                          #:workspace-root [root (state-workspace-root state)])
  (define engine (editor-engine ed))
  (define areas (state-areas state))
  `((schema . ,session-schema)
    (workspace-root . ".")
    (layout . ,(layout->sexpr (state-layout state)))
    (areas . ,(for/list ([aid (in-list (sorted-ids (hash-keys areas)))])
                (cons aid (area->sexpr (hash-ref areas aid)))))
    (current-area . ,(state-current-area state))
    (area-slot . ,(area-slot->sexpr (state-area-slot state)))
    (next-view-id . ,(state-next-view-id state))
    (next-panel-id . ,(state-next-panel-id state))
    (resources . ,(for/list ([r (in-list (resources-list (state-resources state)))])
                    (resource->sexpr engine root r)))
    (buffers . ,(for/list ([did (in-list (sorted-ids (engine-user-doc-ids engine)))])
                  (buffer->sexpr engine did)))))

;;; ════════════════ restore：layout ════════════════

(define (view-exists? engine vid)
  (and vid (engine-view-kind engine vid) #t))

(define (sexpr->node n)
  (cond
    [(and (pair? n) (eq? (car n) 'leaf) (cdr n))
     (make-leaf (cdr n))]
    [(and (list? n) (pair? n) (eq? (car n) 'split))
     (define f (cdr n))
     (define id (field 'id f))
     (define axis (field 'axis f))
     (define ratio (field 'ratio f))
     (define left (sexpr->node (field 'left f)))
     (define right (sexpr->node (field 'right f)))
     (and id
          (memq axis '(lr tb))
          (real? ratio)
          left right
          (split id axis left right ratio))]
    [else #f]))

(define (node-panel-ids n)
  (cond
    [(not n) '()]
    [(leaf? n) (list (leaf-panel-id n))]
    [else (append (node-panel-ids (split-left n))
                  (node-panel-ids (split-right n)))]))

(define (node-max-split-id n)
  (cond
    [(not n) -1]
    [(leaf? n) -1]
    [else
     (max (if (integer? (split-id n)) (split-id n) -1)
          (node-max-split-id (split-left n))
          (node-max-split-id (split-right n)))]))

(define (sexpr->restore x)
  (define r (field 'rect x #f))
  (define pr (field 'parent-rect x #f))
  (define r* (sexpr->rect r))
  (define pr* (sexpr->rect pr))
  (and r* pr* (restore r* pr*)))

(define (sexpr->panel p available?)
  (define id (field 'id p))
  (define kind0 (field 'kind p 'editor))
  (define kind (if (symbol? kind0) kind0 'editor))
  (define views0 (let ([v (field 'views p '())]) (if (list? v) v '())))
  (define views (filter available? views0))
  (define active0 (field 'active p #f))
  (define active (and active0 (memv active0 views) active0))
  (define active* (or active (and (pair? views) (car views)) #f))
  (define fixed-w (let ([v (field 'fixed-w p #f)]) (and (nonneg-int? v) v)))
  (define fixed-h (let ([v (field 'fixed-h p #f)]) (and (nonneg-int? v) v)))
  (define borders
    (let ([v (field 'borders p '())])
      (if (list? v) v '())))
  (define weight (let ([v (field 'weight p 0)]) (if (number? v) v 0)))
  (and id
       (p:make-panel id kind
                   #:views views
                   #:active active*
                   #:fixed-w fixed-w
                   #:fixed-h fixed-h
                   #:hidden? (and (field 'hidden? p #f) #t)
                   #:restore (sexpr->restore (field 'restore p #f))
                   #:borders borders
                   #:face (field 'face p 'window-border)
                   #:weight weight)))

(define (first-focusable l config)
  (for/first ([pid (in-list (layout-visible-panel-ids l))]
              #:when (config-panel-focusable?
                      config (p:panel-kind (layout-panel l pid))))
    pid))

(define (focus-ok? l config id)
  (define p (and id (layout-panel l id)))
  (and p
       (p:panel-visible? p)
       (config-panel-focusable? config (p:panel-kind p))))

(define (restore-focus l config saved)
  (cond
    [(focus-ok? l config saved) saved]
    [saved (or (layout-focus-fallback l config saved)
               (first-focusable l config))]
    [else (first-focusable l config)]))

(define (sexpr->layout data available? config)
  (define root (sexpr->node (field 'root data)))
  (define panels0 (let ([v (field 'panels data '())]) (if (list? v) v '())))
  (define panels
    (for/list ([p (in-list panels0)])
      (sexpr->panel p available?)))
  (define panel-map
    (for/fold ([h (hash)]) ([p (in-list panels)] #:when p)
      (hash-set h (p:panel-id p) p)))
  (define leaves (and root (node-panel-ids root)))
  (cond
    [(or (not root) (null? leaves)) #f]
    [(for/or ([pid (in-list leaves)] #:unless (hash-has-key? panel-map pid)) #t) #f]
    [else
     (define used-map
       (for/fold ([h (hash)]) ([pid (in-list leaves)])
         (hash-set h pid (hash-ref panel-map pid))))
     (define next-split
       (max (let ([v (field 'next-split-id data 0)])
              (if (nonneg-int? v) v 0))
            (add1 (node-max-split-id root))))
     (define l0
       (make-layout #:root root
                    #:panels used-map
                    #:focus #f
                    #:next-split-id next-split))
     (layout-set-focus l0 (restore-focus l0 config (field 'focus data #f)))]))

(define (filter-layout-views l available?)
  (for/fold ([l l]) ([pid (in-list (layout-panel-ids l))])
    (define p (layout-panel l pid))
    (cond
      [(not p) l]
      [else
       (define views (filter available? (p:panel-views p)))
       (define active0 (p:panel-active p))
       (define active (and active0 (memv active0 views) active0))
       (define active* (or active (and (pair? views) (car views)) #f))
       (define-values (l* ok?)
         (layout-panel-update l pid
                              (λ (p) (p:panel-set-views p views active*))))
       (if ok? l* l)])))

(define (editor-panel-ids l)
  (for/list ([pid (in-list (layout-panel-ids l))]
             #:when (eq? (p:panel-kind (layout-panel l pid)) 'editor))
    pid))

;; 多个 editor panel 时，删掉没有任何 view 的 panel（典型：未恢复的 mirror split）。
;; 最后一个 editor panel 即使为空也保留，和现有“空编辑区”模型一致。
(define (prune-empty-editor-panels l config)
  (define pids (editor-panel-ids l))
  (if (<= (length pids) 1)
      l
      (for/fold ([l l]) ([pid (in-list pids)])
        (define p (layout-panel l pid))
        (cond
          [(and p (null? (p:panel-views p)))
           (define-values (l* ok?)
             (layout-panel-remove l pid #:config config))
           (if ok? l* l)]
          [else l]))))

(define (fallback-layout state engine config)
  (define l0 (state-layout state))
  (define available? (λ (vid) (view-exists? engine vid)))
  (define l1 (and l0 (filter-layout-views l0 available?)))
  (define l2 (and l1 (prune-empty-editor-panels l1 config)))
  (and l2 (layout-set-focus l2 (restore-focus l2 config (and l1 (layout-focus l1))))))

;;; ════════════════ restore：areas / slot ════════════════

(define (sexpr->area data available? config)
  (define l0 (sexpr->layout (field 'layout data) available? config))
  (define l1 (and l0 (filter-layout-views l0 available?)))
  (cond
    [(not l1) #f]
    [(for/or ([pid (in-list (layout-panel-ids l1))])
       (not (eq? (p:panel-kind (layout-panel l1 pid)) 'editor)))
     #f]
    [else
     (define l2 (prune-empty-editor-panels l1 config))
     (define focus (restore-focus l2 config (field 'focus data #f)))
     (editor-area (layout-set-focus l2 focus) focus)]))

(define (sexpr->area-slot l data)
  (define s (field 'area-slot data #f))
  (cond
    [(not s) #f]
    [else
     (define parent (field 'parent s #f))
     (define side (field 'side s #f))
     (cond
       [(not (memq side '(left right root))) #f]
       [(not parent) (area-slot #f 'root)]
       [(find-split (layout-root l) parent) (area-slot parent side)]
       [else #f])]))

;;; ════════════════ restore：engine ════════════════

(define (restore-buffer! engine b)
  (define did (field 'id b))
  (define name (let ([v (field 'name b "")]) (if (string? v) v "")))
  (define text (let ([v (field 'text b "")]) (if (string? v) v "")))
  (cond
    [(not (nonneg-int? did)) (void)]
    [(engine-doc-kind engine did) (void)]
    [else
     (engine-create-buffer! engine did name text)
     (define views (field 'views b '()))
     (cond
       [(pair? views)
        (for ([v (in-list views)])
          (define vid (field 'id v))
          (when (and (nonneg-int? vid)
                     (not (engine-view-kind engine vid)))
            (engine-create-view! engine vid did)))]
       [else
        (when (not (engine-view-kind engine did))
          (engine-create-view! engine did did))])]))

(define (restore-view-state! engine v)
  (define vid (field 'id v))
  (define did (field 'doc-id v))
  (define view (and vid (engine-view-object engine vid)))
  (cond
    [(or (not view)
         (and did (not (equal? (engine-view-doc-id engine vid) did))))
     (void)]
    [else
     (define sels (sexpr->selections (field 'selections v)))
     (view-set-selections! view sels #:ensure? #f)
     (define vp (field 'viewport v #f))
     (define mode0 (field 'mode vp 'clip))
     (define mode (if (memq mode0 '(clip wrap)) mode0 'clip))
     (view-set-mode! view mode)
     (define want-ln? (and (field 'line-numbers? vp #f) #t))
     (when (not (equal? (and (view-line-numbers? view) #t) want-ln?))
       (view-toggle-line-numbers! view))
     (case mode
       [(wrap)
        (view-scroll-to-point!
         view (sexpr->point (field 'anchor vp (list 0 0))))]
       [else
        (view-scroll-to-line! view
                              (let ([v* (field 'top-line vp 0)])
                                (if (nonneg-int? v*) v* 0)))
        (view-scroll-to-column! view
                                (let ([v* (field 'left-column vp 0)])
                                  (if (nonneg-int? v*) v* 0)))])]))

(define (restore-resources engine root data)
  (define records (let ([v (field 'resources data '())]) (if (list? v) v '())))
  (for/fold ([rs empty-resources]) ([r (in-list records)])
    (define did (field 'doc-id r))
    (cond
      [(not (eq? (engine-doc-kind engine did) 'user)) rs]
      [else
       (define id (or (field 'id r) did))
       (define (view-of-doc? vid)
         (and (view-exists? engine vid)
              (equal? (engine-view-doc-id engine vid) did)))
       (define views-raw (let ([v (field 'views r '())]) (if (list? v) v '())))
       (define views0 (filter view-of-doc? views-raw))
       (define views
         (if (pair? views0)
             views0
             (or (engine-view-ids-for-doc engine did) '())))
       (define mode0 (field 'mode r 'text))
       (define mode (if (memq mode0 '(racket text)) mode0 'text))
       (define path (session->path root (field 'path r #f)))
       (define name (let ([v (field 'name r "")]) (if (string? v) v "")))
       (define dirty? (and (field 'dirty? r #t) #t))
       (define saved-version
         (if dirty? #f (engine-doc-version engine did)))
       (define res
         (make-resource id did path name views mode saved-version
                        #:command-stack (mode-command-stack mode)))
       (resources-add rs res)])))

;;; ════════════════ restore：入口 ════════════════

(define (max-numeric-id ids)
  (for/fold ([m -1]) ([id (in-list ids)])
    (if (and (integer? id) (> id m)) id m)))

(define (restore-session! ed state data)
  (unless (and (list? data) (equal? (field 'schema data) session-schema))
    (error 'restore-session! "session schema 不匹配：~a" (field 'schema data)))
  (define engine (editor-engine ed))
  (define config (state-layout-config state))
  (define root (state-workspace-root state))
  (define buffers (let ([v (field 'buffers data '())]) (if (list? v) v '())))
  ;; 先解析 layout / areas：结构错误在删旧 doc 之前暴露，host 可以原样回退。
  (void (sexpr->layout (field 'layout data #f) (λ (_vid) #t) config))
  (for ([pair (in-list (let ([v (field 'areas data '())]) (if (list? v) v '())))])
    (void (sexpr->area (cdr pair) (λ (_vid) #t) config)))
  ;; 有 buffer 记录时，丢掉 bootstrap 的初始 user doc / view，按 session 重建。
  (when (pair? buffers)
    (for ([did (in-list (engine-user-doc-ids engine))])
      (engine-remove-doc! engine did)))
  (for ([b (in-list buffers)]) (restore-buffer! engine b))
  (for ([b (in-list buffers)])
    (define views (let ([v (field 'views b '())]) (if (list? v) v '())))
    (for ([v (in-list views)])
      (restore-view-state! engine v)))
  (define available? (λ (vid) (view-exists? engine vid)))
  (define l0 (sexpr->layout (field 'layout data #f) available? config))
  (define l1 (and l0 (filter-layout-views l0 available?)))
  (define l2 (and l1 (prune-empty-editor-panels l1 config)))
  (define l-final
    (or (and l2
             (layout-set-focus l2
                               (restore-focus l2 config
                                              (and l0 (layout-focus l0)))))
        (fallback-layout state engine config)))
  (define areas-list
    (let ([v (field 'areas data '())]) (if (list? v) v '())))
  (define areas0
    (for/fold ([h (hash)]) ([pair (in-list areas-list)])
      (define aid (car pair))
      (define area (sexpr->area (cdr pair) available? config))
      (if area (hash-set h aid area) h)))
  (define current0 (field 'current-area data 1))
  (define current
    (if (nonneg-int? current0) current0 1))
  (define areas
    (hash-remove areas0 current))
  (define saved-slot (field 'area-slot data #f))
  (define slot (and l-final (sexpr->area-slot l-final data)))
  (define areas*
    (cond
      [(and saved-slot slot) areas]
      [saved-slot (hash)]
      [else (hash)]))
  (define current* current)
  (define resources (restore-resources engine root data))
  (define all-ids
    (append (engine-doc-ids engine)
            (engine-user-view-ids engine)
            (engine-ui-view-ids engine)
            (engine-derived-view-ids engine)))
  (define next-view
    (max (let ([v (field 'next-view-id data 10)])
           (if (nonneg-int? v) v 10))
         (add1 (max-numeric-id all-ids))))
  (define panel-ids
    (append (if l-final (layout-panel-ids l-final) '())
            (append* (for/list ([a (in-hash-values areas*)])
                       (layout-panel-ids (editor-area-layout a))))))
  (define next-panel
    (max (let ([v (field 'next-panel-id data 100)])
           (if (nonneg-int? v) v 100))
         (add1 (max-numeric-id panel-ids))))
  (define state1
    (if l-final (state-with-layout state l-final) state))
  (define state2 (state-with-areas state1 areas*))
  (define state3 (state-with-current-area state2 current*))
  (define state4 (state-with-area-slot state3
                                       (if (and saved-slot slot) slot #f)))
  (define state5 (state-with-resources state4 resources))
  (state-with-next-panel-id
   (state-with-next-view-id state5 next-view)
   next-panel))
