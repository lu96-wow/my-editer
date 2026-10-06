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

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/layer.rkt"
         "../kernel/session.rkt"
         "../kernel/frame.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/hooks.rkt"
         "../kernel/table.rkt"
         "../kernel/binding.rkt"
         "../kernel/overlay.rkt"
         "../kernel/wrap.rkt"
         "lang/ident.rkt" "lang/source.rkt" "lang/complete.rkt" "lang/docs.rkt" "lang/file-kind.rkt"
         "lang/module-index.rkt"
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
  (define inst (input-find (session-input (ctx-session ctx)) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (cond
       [(equal? (cs-pending st) req-id)
        (list (e-input-set 'complete (struct-copy cs st
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
       (frame-contains? (session-frame (ctx-session ctx)) vid)
       (doc-applies? ctx 'complete)))

;; 现算模块 / 池 / 前缀 / 候选（新建会话用）。→ (values mods pool prefix cands)
;; require 位置 → 模块路径补全（mods = #f：不做文档查询）。
;; 词候选用共享词法器 document-words —— 与高亮词色同一套词法，不读高亮的私有状态表。
(define (fresh-candidates ctx vid text p)
  (define prefix (prefix-at text (point-line p) (point-column p)))
  (cond
    [(require-context? text (point-line p) (point-column p))
     (define pool (force module-paths))
     (values #f pool prefix (candidates-for pool prefix))]
    [else
     (define mods (view-modules ctx vid))
     (define pool (completion-pool #:modules mods
                                   #:locals (source-definitions text)
                                   #:words (document-words text)))
     (values mods pool prefix (candidates-for pool prefix))]))

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
  (append (list (if push? (e-input-push 'complete st) (e-input-set 'complete st)))
          await))

(define (cmd-complete ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not (completable-view? ctx vid)) '()]
    [else
     (define ed (session-editor s))
     (define text (editor-view-string ed vid))
     (define p (editor-view-point ed vid))
     (define-values (mods pool prefix cands) (fresh-candidates ctx vid text p))
     (cond
       [(not (pair? cands)) '()]
       ;; 已弹出会话时 C-n 只刷新，不重复入栈。
       [else (menu-effects ctx vid mods pool cands p prefix
                           (not (input-find (session-input s) 'complete)))])]))

(define (cmd-complete-move ctx ev delta)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
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
        (append (list (e-input-set 'complete st*)) await)])]))

(define (cmd-complete-accept ctx ev)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define ed (session-editor s))
     (define vid (cs-vid st))
     (define cand (list-ref (cs-cands st) (cs-idx st)))
     (define p (editor-view-point ed vid))
     ;; typing? = #f：接受不是“用户打字”，不再触发 after-insert 自动弹。
     (list (e-input-pop 'complete)
           (e-move vid (selections-one (selection (cs-start st) p)))
           (e-type vid cand #f #f))]))

(define (cmd-complete-cancel ctx ev) (list (e-input-pop 'complete)))

;;; ================= 钩子 =================

;; after-insert：打字 / 退格 / 粘贴后调用。
;;   无会话 → 自动弹（与 C-n 同一套候选）；有会话 → 复用池 refine。
(define (complete-refine ctx _args)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not (completable-view? ctx vid)) (list (e-input-pop 'complete))]
    [else
     (define ed (session-editor s))
     (define text (editor-view-string ed vid))
     (define p (editor-view-point ed vid))
     (define inst (input-find (session-input s) 'complete))
     (define st0 (and inst (layer-inst-state inst)))
     (cond
       [(and st0 (eqv? (cs-vid st0) vid))
        (define prefix (prefix-at text (point-line p) (point-column p)))
        (define cands (candidates-for (cs-pool st0) prefix))
        (cond
          [(not (pair? cands)) (list (e-input-pop 'complete))]
          [else (menu-effects ctx vid (cs-mods st0) (cs-pool st0) cands p prefix #f)])]
       [else
        (define-values (mods pool prefix cands) (fresh-candidates ctx vid text p))
        (cond
          [(not (pair? cands)) (list (e-input-pop 'complete))]
          [else (menu-effects ctx vid mods pool cands p prefix #t)])])]))

(define (complete-cancel-hook ctx _args) (list (e-input-pop 'complete)))

;;; ================= 浮层 =================

(define complete-face 'state)
(define complete-max-rows 10)
(define complete-doc-max-rows 18)

(define (complete-panes ctx)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
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
                 (list (contrib 'doc-scope 'complete 0 (doc-scope racket-buffer?))
                       (contrib 'deco 'complete 0 (deco 'complete complete-panes))
                       (contrib 'layer-spec 'complete 0 complete-layer)
                       (contrib 'binding 'complete 0 (keybinding 'edit (key 'n 'ctrl) 'complete))
                       (contrib 'command 'complete 0 cmd-complete)
                       (contrib 'command 'complete-move 0 cmd-complete-move)
                       (contrib 'command 'complete-accept 0 cmd-complete-accept)
                       (contrib 'command 'complete-cancel 0 cmd-complete-cancel)
                       (contrib 'hook 'complete-refine 0 (make-hook 'after-insert complete-refine))
                       (contrib 'hook 'complete-cancel-nav 0 (make-hook 'after-nav complete-cancel-hook))
                       (contrib 'hook 'complete-cancel-focus 0 (make-hook 'focus-changed complete-cancel-hook))))])
    (reg-add r c)))
