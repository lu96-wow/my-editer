#lang racket

;;; lab/builtin/complete.rkt —— 补全菜单（layer + deco 浮层 + 异步内嵌文档）。
;;;
;;; 触发：after-insert（打字 / 退格 / 粘贴）自动弹，C-n 显式弹；Escape / 导航 / 失焦取消。
;;; layer 'complete：fallthrough（打字仍落 base）+ pop never（显式 accept/cancel）。
;;; deco 'complete：每帧纯函数产菜单 pane（锚在光标），选中项内嵌 bluebox 文档。
;;; 候选来自 lang：当前文件的 #lang/require 导出 + 本地定义 + **文件里出现过的词**。
;;;
;;; 组合方式：模块上下文用 `doc-job` 的 `view-modules`，异步文档用 `doc-await`
;;; （请求 + 文档句柄闸门）；本文件只负责「菜单状态 + 装文档」。轮询由 doc-job 统一。

(require racket/string
         "../kernel/api.rkt"
         "lang/ident.rkt" "lang/source.rkt" "lang/complete.rkt" "lang/docs.rkt" "lang/file-kind.rkt"
         "lang/module-index.rkt" "lang/word-index.rkt"
         "doc-scope.rkt"
         "doc-job.rkt")

(provide register-complete! (struct-out cs))

;;   cands   : (listof string) 当前过滤后的候选
;;   idx     : 选中下标
;;   start   : 前缀起点（接受时替换 [start, 光标)）
;;   vid     : 发起时的编辑 view（锚点 + 文档闸门）
;;   mods    : 查候选 / 查文档的模块表
;;   pool    : 本次会话的完整候选池（复用）
;;   doc     : 选中项文档（bluebox）/ #f
;;   pending : 当前选中项对应的文档请求 id / #f（迟到的旧请求不装）
(struct cs (cands idx start vid mods pool doc pending) #:transparent)

(define complete-keys
  (kbd (key 'up)     '(complete-move -1)
       (key 'down)   '(complete-move 1)
       (key 'tab)    'complete-accept
       (key 'enter)  'complete-accept
       (key 'escape) 'complete-cancel))

(define complete-layer
  (make-layer 'complete
              #:tables (λ (ctx inst) (list complete-keys))
              #:capture 'fallthrough
              #:pop 'never))

;;; ================= 状态构造 / 异步装文档 =================

;; 装文档的 on-result：请求 id 仍是 menu 的 pending → 装；否则丢弃。
(define ((install-doc req-id) ctx result)
  (define inst (stack-find (session-input (ctx-session ctx)) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (cond
       [(equal? (cs-pending st) req-id)
        (list (e-layer-set 'complete (struct-copy cs st
                                                  [doc (result->doc result)]
                                                  [pending #f])))]
       [else '()])]))

;; 新菜单状态：候选 + 选中候选的异步文档（模块路径补全 mods = #f → 不查文档）。
;; 第二个返回值是 effect 列表（可为空）。
(define (make-cs ctx vid mods pool cands idx start)
  (cond
    [mods
     (define req-id (doc-request! ctx (list-ref cands idx) mods))
     (values (cs cands idx start vid mods pool #f req-id)
             (list (doc-await ctx vid req-id (install-doc req-id))))]
    [else
     (values (cs cands idx start vid mods pool #f #f) '())]))

;;; ================= 命令 =================

;; 补全只在「编辑视图 + 该文档适用」上启用（适用范围由 doc-scope 声明：当前 = Racket）。
;; 非 .rkt（如 a.c）不弹菜单、不 auto-pop，也不响应 C-n。
(define (completable-view? ctx vid)
  (and vid
       (main-view? (ctx-session ctx) vid)
       (doc-applies? ctx 'complete)))

;; 每词缓存：只记「这个词是否 require 上下文」+「该 did 的模块表」。真正的候选池按
;; did 缓存（见 doc-pool），不再每词重建。形状 (vector vid line word-start prefix req? mods)。
;; prefix 只用于校验：词只能向前长，当前前缀不再以缓存前缀开头（退格/改词）→ 失效。
(define word-cache (box #f))

(define (word-cache-hit vid line word-start prefix)
  (define c (unbox word-cache))
  (and (vector? c)
       (eqv? (vector-ref c 0) vid)
       (= (vector-ref c 1) line)
       (= (vector-ref c 2) word-start)
       (string-prefix? prefix (vector-ref c 3))
       c))

;; 每 editor 一份的 feature service：增量词表 + 每 did 的模块表 / 候选池 / 词表所反映的文档。
;; （did / vid 在不同 editor 间会从 0 重数，所以不能放模块级全局。）
;; wdocs : hash did -> document 句柄（词表影子对应的版本；换了 → 影子过期，整篇重建）。
(struct c-svc (words mods pools wdocs) #:transparent)
(define (c-svc-of ctx) (service-ref ctx 'complete))
(define (complete-svc-init ctx)
  (service-put ctx 'complete (c-svc (make-hash) (make-hash) (make-hash) (make-hash))))

;; 整篇重建词表，并把版本钉到当前文档句柄。
(define (word-index-rebuild! ctx did text)
  (define svc (c-svc-of ctx))
  (define ed (session-editor (ctx-session ctx)))
  (hash-set! (c-svc-words svc) did (word-index-open text))
  (hash-set! (c-svc-wdocs svc) did (editor-document-handle ed did)))

;; 每 did 的增量词表：首次 / 影子过期就整篇建；否则 after-edit 增量维护。
(define (word-index-for ctx did get-text)
  (define svc (c-svc-of ctx))
  (define tbl (c-svc-words svc))
  (define cur (editor-document-handle (session-editor (ctx-session ctx)) did))
  (define w (hash-ref tbl did #f))
  (cond
    [(and w (eq? (hash-ref (c-svc-wdocs svc) did #f) cur)) w]
    [else
     ;; 影子过期 / 首次：重建词表，并让候选池失效（池含旧词）。
     (define w* (word-index-open (get-text)))
     (hash-set! tbl did w*)
     (hash-set! (c-svc-wdocs svc) did cur)
     (hash-remove! (c-svc-pools svc) did)
     w*]))

;; 每 did 的模块表（require 只读文件头部，header 改了才失效）。
(define (doc-mods ctx vid did get-text)
  (define h (c-svc-mods (c-svc-of ctx)))
  (cond
    [(hash-ref h did #f)]
    [else
     (define-values (lang forms) (requires-context (get-text)))
     (define mods (view-modules/context ctx vid lang forms))
     (hash-set! h did mods)
     mods]))

;; 每 did 的候选池：模块导出 + 该文档所有词。只建一次，之后新词增量 append。
(define (doc-pool ctx did mods w)
  (define h (c-svc-pools (c-svc-of ctx)))
  (define e (hash-ref h did #f))
  (cond
    [e (unbox (vector-ref e 0))]
    [else
     (define set (make-hash))
     (define lst
       (for/fold ([acc '()])
                 ([s (in-list (append (append* (for/list ([m (in-list mods)]) (module-exports m)))
                                      (word-index-words w)))])
         (cond [(hash-ref set s #f) acc]
               [else (hash-set! set s #t) (cons s acc)])))
     (define e* (vector (box (reverse lst)) set))
     (hash-set! h did e*)
     (unbox (vector-ref e* 0))]))

(define (doc-pool-add! ctx did words)
  (define e (hash-ref (c-svc-pools (c-svc-of ctx)) did #f))
  (when e
    (define set (vector-ref e 1))
    (define b (vector-ref e 0))
    (for ([s (in-list words)])
      (unless (hash-ref set s #f)
        (hash-set! set s #t)
        (set-box! b (cons s (unbox b)))))))

;; header（#lang / require）在文件头部；改到这里就让模块表与池失效，下次重建。
(define header-lines 300)

(define (doc-invalidate! ctx did)
  (hash-remove! (c-svc-mods (c-svc-of ctx)) did)
  (hash-remove! (c-svc-pools (c-svc-of ctx)) did)
  (set-box! word-cache #f))

;; 光标处的前缀：只读一行（O(行)），不整篇取串。
(define (view-prefix ed vid p)
  (define s (editor-view-line-before ed vid p))
  (prefix-at s 0 (string-length s)))

;; require 上下文只看光标前的一段窗口（require form 很少超百行），
;; 避免 text-before + last-open-paren 每词扫全文。
(define require-window-lines 100)
(define (require-window ed vid line col)
  (define l0 (max 0 (- line require-window-lines)))
  (define did (editor-view-document-id ed vid))
  (define doc (editor-document-handle ed did))
  (define win (document-range-text doc (range (point l0 0) (point line col))))
  (values win (- line l0) col))

;; 现算模块 / 池 / 前缀 / 候选（新建会话用）。→ (values mods pool cands)
;; prefix 由调用方用 `view-prefix` 算好（它只需一行）；get-text 是取全文的 thunk，
;; 只在某 did 第一次用时才调用。
;; require 位置 → 模块路径补全（mods = #f：不做文档查询）。
(define (fresh-candidates ctx vid get-text p prefix)
  (define line (point-line p))
  (define col (point-column p))
  (cond
    [(zero? (string-length prefix))
     ;; 空前缀永远没有候选；不建池，打字里的空格 / 括号就不会白扫全文。
     (values #f '() #f)]
    [else
     (define word-start (- col (string-length prefix)))
     (define hit (word-cache-hit vid line word-start prefix))
     (define did (editor-view-document-id (session-editor (ctx-session ctx)) vid))
     (cond
       [hit
        (cond
          [(vector-ref hit 4) (define pool (force module-paths))
                              (values #f pool (candidates-for pool prefix))]
          [else
           (define mods (vector-ref hit 5))
           (define w (word-index-for ctx did get-text))
           (define pool (doc-pool ctx did mods w))
           (values mods pool (candidates-for pool prefix))])]
       [else
        (define-values (win wline wcol)
          (require-window (session-editor (ctx-session ctx)) vid line col))
        (cond
          [(require-context? win wline wcol)
           (define pool (force module-paths))
           (define cands (candidates-for pool prefix))
           (set-box! word-cache (vector vid line word-start prefix #t #f))
           (values #f pool cands)]
          [else
           (define w (word-index-for ctx did get-text))
           (define mods (doc-mods ctx vid did get-text))
           (define pool (doc-pool ctx did mods w))
           (set-box! word-cache (vector vid line word-start prefix #f mods))
           (values mods pool (candidates-for pool prefix))])])]))

;; 过滤 + 去掉与前缀一模一样的候选（已经打完，不必再提示自己）。
(define (candidates-for pool prefix)
  (and (positive? (string-length prefix))
       (let ([cs (filter-pool pool prefix)])
         (if (member prefix cs) (remove prefix cs) cs))))

(define (prefix-start p prefix)
  (point (point-line p) (max 0 (- (point-column p) (string-length prefix)))))

;; 用候选建菜单；push? = 新建会话（入栈），否则刷新（set）。
(define (menu-effects ctx vid mods pool cands p prefix push?)
  (define-values (st await) (make-cs ctx vid mods pool cands 0 (prefix-start p prefix)))
  (append (list (if push? (e-layer-push 'complete st) (e-layer-set 'complete st)))
          await))

(define (cmd-complete ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not (completable-view? ctx vid)) '()]
    [else
     (define ed (session-editor s))
     (define p (editor-view-point ed vid))
     (define prefix (view-prefix ed vid p))
     (define-values (mods pool cands)
       (fresh-candidates ctx vid (λ () (editor-view-string ed vid)) p prefix))
     (cond
       [(not (pair? cands)) '()]
       ;; 已弹出会话时 C-n 只刷新，不重复入栈。
       [else (menu-effects ctx vid mods pool cands p prefix
                           (not (stack-find (session-input s) 'complete)))])]))

(define (cmd-complete-move ctx ev delta)
  (define s (ctx-session ctx))
  (define inst (stack-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define n (length (cs-cands st)))
     (cond
       [(zero? n) '()]
       [else
        (define i (modulo (+ (cs-idx st) delta) n))
        (define-values (st* await)
          (make-cs ctx (cs-vid st) (cs-mods st) (cs-pool st) (cs-cands st) i (cs-start st)))
        (append (list (e-layer-set 'complete st*)) await)])]))

(define (cmd-complete-accept ctx ev)
  (define s (ctx-session ctx))
  (define inst (stack-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define ed (session-editor s))
     (define vid (cs-vid st))
     (define cand (list-ref (cs-cands st) (cs-idx st)))
     (define p (editor-view-point ed vid))
     ;; typing? = #f：接受不是“用户打字”，不再触发 after-insert 自动弹。
     (list (e-layer-pop 'complete)
           (e-move vid (selections-one (selection (cs-start st) p)))
           (e-type vid cand #f #f))]))

(define (cmd-complete-cancel ctx ev) (list (e-layer-pop 'complete)))

;;; ================= 钩子 =================

;; after-insert：打字 / 退格 / 粘贴后调用。
;;   无会话 → 自动弹（与 C-n 同一套候选）；有会话 → 复用池 refine。
(define (complete-refine ctx _args)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not (completable-view? ctx vid)) (list (e-layer-pop 'complete))]
    [else
     (define ed (session-editor s))
     (define p (editor-view-point ed vid))
     (define prefix (view-prefix ed vid p))
     (define inst (stack-find (session-input s) 'complete))
     (define st0 (and inst (layer-inst-state inst)))
     (cond
       [(and st0 (eqv? (cs-vid st0) vid))
        (define cands (candidates-for (cs-pool st0) prefix))
        (cond
          [(not (pair? cands)) (list (e-layer-pop 'complete))]
          [else (menu-effects ctx vid (cs-mods st0) (cs-pool st0) cands p prefix #f)])]
       [else
        (define-values (mods pool cands)
          (fresh-candidates ctx vid (λ () (editor-view-string ed vid)) p prefix))
        (cond
          [(not (pair? cands)) (list (e-layer-pop 'complete))]
          [else (menu-effects ctx vid mods pool cands p prefix #t)])])]))

(define (complete-cancel-hook ctx _args) (list (e-layer-pop 'complete)))

;; after-edit：把一次编辑的 diff 增量喂给该 did 的词表（没有词表就跳过，首用时才整篇建）；
;; 新词增量 append 到该 did 的候选池；header（前 header-lines 行）改了就让模块表/池失效。
;; 坐标越界（影子因程序写入而过期）→ 整篇重建，不硬算。
(define (word-note-hook ctx args)
  (define vid (car args))
  (define changes (cadr args))
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define did (editor-view-document-id ed vid))
  (define svc (c-svc-of ctx))
  (define w (hash-ref (c-svc-words svc) did #f))
  (when (and w (pair? changes))
    (define edits
      (for/list ([ch (in-list changes)])
        (define b (change-before ch))
        (list (point-line (range-start b)) (point-column (range-start b))
              (point-line (range-end b)) (point-column (range-end b))
              (editor-view-change-text ed vid ch))))
    (cond
      [(word-index-fits? w edits)
       (define added (word-index-change w edits))
       (doc-pool-add! ctx did added)
       (when (for/or ([e (in-list edits)]) (< (car e) header-lines))
         (doc-invalidate! ctx did))]
      [else
       ;; 影子与文档脱节（如 editor-view-assign! 不过 after-edit）→ 整篇重建。
       (word-index-rebuild! ctx did (editor-view-string ed vid))
       (doc-invalidate! ctx did)])
    ;; 钉住本帧看到的文档版本，“已同步”。
    (hash-set! (c-svc-wdocs svc) did (editor-document-handle ed did)))
  '())

;; before-render：程序写入（assign）不触发 after-edit，会绕过词表；
;; 这里对每个已建词表的 did 校版本，换了就重建（正常编辑已在 after-edit 里钉过，不会重建）。
(define (word-resync-hook ctx _args)
  (define svc (c-svc-of ctx))
  (define ed (session-editor (ctx-session ctx)))
  (define tbl (c-svc-words svc))
  (define wdocs (c-svc-wdocs svc))
  ;; 防御：万一有直接关文档而没走 document-closed 的路径，清掉死 did。
  (define live (editor-document-id-list ed))
  (define dead (for/list ([(did _w) (in-hash tbl)] #:unless (memv did live)) did))
  (for ([did (in-list dead)])
    (hash-remove! tbl did)
    (hash-remove! wdocs did))
  (define stale
    (for/list ([(did _w) (in-hash tbl)]
               #:when (memv did live)
               #:unless (eq? (hash-ref wdocs did #f) (editor-document-handle ed did)))
      did))
  (for ([did (in-list stale)])
    (word-index-rebuild! ctx did (editor-document-string ed did))
    (doc-invalidate! ctx did))
  '())

(define (word-closed-hook ctx args)
  (define did (car args))
  (hash-remove! (c-svc-words (c-svc-of ctx)) did)
  (hash-remove! (c-svc-wdocs (c-svc-of ctx)) did)
  (doc-invalidate! ctx did)
  '())

;;; ================= 浮层 =================

(define complete-face 'state)
(define complete-max-rows 10)
(define complete-doc-max-rows 18)

(define (complete-panes ctx)
  (define s (ctx-session ctx))
  (define inst (stack-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define vid (cs-vid st))
     (define ed (session-editor s))
     (define-values (arow acol) (anchor-screen-pos ctx vid (editor-view-point ed vid)))
     (cond
       [(not arow) '()]
       [else
        (define cands (cs-cands st))
        (define idx (cs-idx st))
        (define n (length cands))
        (define d (cs-doc st))
        (define avail-below (- (session-height s) (add1 arow)))
        (define avail-above arow)
        (define budget (max 1 (- (max avail-above avail-below) 2)))
        (define mrows (min complete-max-rows n budget))
        (define start (max 0 (min (- idx (quotient mrows 2)) (- n mrows))))
        (define shown (take (drop cands start) mrows))
        (define menu-cw (+ 2 (for/fold ([mx 0]) ([x (in-list shown)]) (max mx (string-length x)))))
        (define max-cw (max 10 (- (session-width s) 4)))
        (define inner (min max-cw (max menu-cw (if d 48 0))))
        (define doc-budget (max 0 (- budget mrows (if d 1 0))))
        (define doc-lines (and d (list->vector (wrap-lines (doc->text d) inner))))
        (define doc-rows (if doc-lines
                             (max 0 (min complete-doc-max-rows (vector-length doc-lines) doc-budget))
                             0))
        (define show-doc? (and d (positive? doc-rows)))
        (define menu-rows
          (for/list ([i (in-range mrows)])
            (define x (list-ref shown i))
            (define selected? (= (+ start i) idx))
            (cons (string-append " " x) (if selected? (cons 'cursor complete-face) complete-face))))
        (define doc-row-list
          (if show-doc?
              (for/list ([i (in-range doc-rows)]) (cons (vector-ref doc-lines i) complete-face))
              '()))
        (define sep (if show-doc? (list (cons (make-string inner #\u2500) 'bar)) '()))
        (define h (+ mrows (if show-doc? (+ 1 doc-rows) 0) 2))
        (define body (if (> h avail-below)
                         (append doc-row-list sep menu-rows)
                         (append menu-rows sep doc-row-list)))
        (define-values (top left)
          (anchor-placement arow acol inner h (session-width s) (session-height s)))
        (list (frame-pane 'complete top left inner body 10))])]))

;;; ================= 注册 =================

(define (register-complete! r)
  (for/fold ([r (register-doc-job! r)])
            ([c (in-list
                 (list (contrib 'init 'complete-svc complete-svc-init)
                       (contrib 'doc-scope 'complete (doc-scope racket-buffer?))
                       (contrib 'deco 'complete (deco 'complete complete-panes))
                       (contrib 'layer-spec 'complete complete-layer)
                       (contrib 'command 'complete cmd-complete)
                       (contrib 'command 'complete-move cmd-complete-move)
                       (contrib 'command 'complete-accept cmd-complete-accept)
                       (contrib 'command 'complete-cancel cmd-complete-cancel)
                       (contrib 'hook 'complete-refine (make-hook 'after-insert complete-refine))
                       (contrib 'hook 'word-note (make-hook 'after-edit word-note-hook))
                       (contrib 'hook 'word-resync (make-hook 'before-render word-resync-hook))
                       (contrib 'hook 'word-closed (make-hook 'document-closed word-closed-hook))
                       (contrib 'hook 'complete-cancel-nav (make-hook 'after-nav complete-cancel-hook))
                       (contrib 'hook 'complete-cancel-focus (make-hook 'focus-changed complete-cancel-hook))))])
    (reg-add r c)))
