#lang racket

;;; edit/plugin/builtin/completion.rkt —— 补全插件（模块路径 / 模块导出 / 本地定义 / 文档词）
;;;
;;; 菜单是**叠加层（deco）视图**（不抢焦点）；打开时压一个输入层（模态键表）：
;;;   · 上下/Enter/Tab/Esc 由层接管；
;;;   · 普通字符层里没有 → fallthrough 到文档键表 → cmd-insert → 本 handler 接手：
;;;     先插入再按新前缀从**复用池**过滤。
;;; 接受：把 [前缀起点, 光标) 换成候选。
;;;
;;; 慢部分（已安装模块路径 / module->exports）丢给 `plugin/runner.rkt` 的 place worker：
;;;   · 池按「上下文键」缓存（'module / (exports . mods)）；
;;;   · 未缓存 → 提交请求 + `session-await` 闸门；结果由 before-render 轮询取回并装池；
;;;   · 到齐后 `maybe-open` 按当前光标上下文重新判断 → 开菜单（或再请求下一键）。
;;; 本地信息（文档词 / 顶层定义 / require 解析）留主线程（快）。
;;; 渲染唤醒：会话有未决异步时，tui 主循环用 read-event-noblock 小幅轮询重绘。

(require racket/list
         racket/path
         racket/runtime-path
         racket/string
         "../registry.rkt"
         "../runner.rkt"
         "../../feature/api.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../lang/source.rkt"
         "../../lang/module-index.rkt"
         "../../lang/pool.rkt")

(provide completion-install completion-spec)

;;; ---------- 服务状态 ----------

(struct c-svc (menu runner cache pending) #:transparent)
;; menu    : box (menu | #f)      当前打开的菜单
;; runner  : box (runner | #f)    惰性创建（place 只能在 with-tui 之后建）
;; cache   : hash 上下文键 -> (listof string)   模块路径 / 导出名
;; pending : hash 上下文键 -> #t                已提交、未回来

(struct menu (vid mvid did start cands idx pool) #:transparent)
;; vid   : 编辑器 view（发起补全者，接受时改它）
;; mvid  : 菜单视图
;; did   : 发起时编辑器文档 id（关文档时以此取消菜单）
;; start : (cons line col)  前缀起点
;; cands : (listof string)  当前过滤后的候选
;; idx   : 选中下标
;; pool  : (listof string)  本次会话的完整候选池（复用）

;; 补全上下文：决定池从哪来、缓存键是什么。
(struct ctx (key locals words) #:transparent)
;; key    : 'module | (list 'exports mods) | #f    #f = 只需文档词（同步，无需 worker）
;; locals : (listof symbol)   文件顶层定义名
;; words  : (listof string)   文件里出现过的词

(define (completion-svc s) (session-service-ref s 'complete))
(define max-rows 10)
(define menu-deep 2000)                            ; 远高于布局树

;;; ---------- 上下文 / 池 ----------

(define (make-ctx s vid text line col)
  (cond
    [(require-context? text line col) (ctx 'module '() '())]
    [else
     (define did (session-view-did s vid))
     (define path (and did (session-file-path s did)))
     (define words (document-words text))
     (cond
       [(not (racket-file? path)) (ctx #f '() words)]
       [else
        (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                             (current-directory)))
        (define-values (lang forms) (requires-context text))
        (define mods (requires-of-forms lang forms #:base-dir base-dir))
        ;; 无 require/语言 → 不需要 worker（池只需本地词/定义）
        (ctx (and (pair? mods) (list 'exports mods))
             (definitions-of-forms forms)
             words)])]))

;; 缓存命中（key #f 视为永远命中：只需本地词）。
(define (ctx-cached? svc ctx)
  (or (not (ctx-key ctx)) (hash-has-key? (c-svc-cache svc) (ctx-key ctx))))

;; 完整池 = 缓存基底 + 本地定义 + 文档词（key='module 时基底即全部）。
(define (ctx-pool svc ctx)
  (cond
    [(eq? (ctx-key ctx) 'module) (hash-ref (c-svc-cache svc) 'module '())]
    [else
     (define base (if (ctx-key ctx) (hash-ref (c-svc-cache svc) (ctx-key ctx) '()) '()))
     (distinct-strings (append base
                               (map symbol->string (ctx-locals ctx))
                               (ctx-words ctx)))]))

;;; ---------- worker（place，惰性） ----------

(define-runtime-path worker-path "complete-worker.rkt")

(define (ensure-runner svc)
  (or (unbox (c-svc-runner svc))
      (let ([r (make-place-runner worker-path 'main)])
        (set-box! (c-svc-runner svc) r)
        r)))

;; 请求键 → worker 请求。'module → (module-paths)；(exports . mods) → 自身。
(define (ctx-request key)
  (if (eq? key 'module) '(module-paths) key))

;;; ---------- 菜单内容 / 几何 ----------

(define (menu-doc cands idx)
  (define n (length cands))
  (define rows (min n max-rows))
  (define start (max 0 (min (- idx (quotient rows 2)) (- n rows))))
  (define shown (take (drop cands start) rows))
  (panel-doc
   (for/list ([c (in-list shown)] [i (in-naturals)])
     (list (string-append " " c)
           (if (= (+ start i) idx) 'complete-selected 'complete)))))

;; 菜单在光标下方（放不下则上方）；宽随候选，钳到屏幕内。→ (values x y w h)
(define (menu-rect s vid cands)
  (define-values (col row) (session-view-cursor-screen s vid))
  (define c (or col 0))
  (define r (or row 0))
  (define n (length cands))
  (define h (min n max-rows))
  (define want (+ 2 (for/fold ([m 0]) ([x (in-list cands)]) (max m (string-length x)))))
  (define w (min (max 10 (- (session-width s) 2)) (max 10 want)))
  (define x (max 0 (min c (- (session-width s) w))))
  (define y (if (<= (+ r 1 h) (session-height s)) (+ r 1) (max 0 (- r h))))
  (values x y w h))

;; 每帧叠加层：菜单打开时把菜单视图摆在光标处。
(define (menu-panes s)
  (define svc (completion-svc s))
  (define m (and svc (unbox (c-svc-menu svc))))
  (cond
    [(not m) '()]
    [else
     (define-values (x y w h) (menu-rect s (menu-vid m) (menu-cands m)))
     (list (placed (menu-mvid m) x y w h menu-deep))]))

;;; ---------- 打开 / 刷新 / 移动 / 接受 / 关闭 ----------

(define (open-menu! s vid line col prefix pool)
  (define cands (filter-pool pool prefix))
  (cond
    [(null? cands) s]
    [else
     (define svc (completion-svc s))
     (define start (cons line (- col (string-length prefix))))
     (define-values (x y w h) (menu-rect s vid cands))
     (define-values (s1 _mdid mvid)
       (session-add-document s (menu-doc cands 0) w h #:name "*complete*"))
     (set-box! (c-svc-menu svc) (menu vid mvid (session-view-did s vid) start cands 0 pool))
     ;; 登记叠加 vid（dock / 不入缓冲区）+ 叠加层（几何每帧算）
     (define s2 (session-overlay-add s1 mvid))
     (define s3 (session-deco-add s2 (deco 'complete menu-panes)))
     (session-layer-push s3 'complete complete-keys)]))

;; 按当前光标：缓存命中就开菜单；否则提交异步请求。
(define (maybe-open s)
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [(unbox (c-svc-menu svc)) s]
    [else
     (define vid (session-focus-vid s))
     (cond
       [(not vid) s]
       [else
        (define text (session-view-string s vid))
        (define line (session-view-point-line s vid))
        (define col (session-view-point-column s vid))
        (define prefix (prefix-at text line col))
        (cond
          [(zero? (string-length prefix)) s]
          [else
           (define ctx (make-ctx s vid text line col))
           (cond
             [(ctx-cached? svc ctx) (open-menu! s vid line col prefix (ctx-pool svc ctx))]
             [else (request-pool! s svc ctx)])])])]))

;; 提交请求 + 登记闸门；结果回来装池并重试开菜单。
(define (request-pool! s svc ctx)
  (define key (ctx-key ctx))
  (cond
    [(hash-ref (c-svc-pending svc) key #f) s]
    [else
     (define id (runner-submit! (ensure-runner svc) (ctx-request key)))
     (hash-set! (c-svc-pending svc) key #t)
     (session-await
      s id key (lambda (_s _tok) #t)
      (lambda (s result)
        (hash-set! (c-svc-cache svc) key result)
        (hash-remove! (c-svc-pending svc) key)
        (maybe-open s)))]))

(define (do-refine s)
  (define svc (completion-svc s))
  (define m (unbox (c-svc-menu svc)))
  (define vid (menu-vid m))
  (define text (session-view-string s vid))
  (define line (session-view-point-line s vid))
  (define col (session-view-point-column s vid))
  (define prefix (prefix-at text line col))
  (define cands (filter-pool (menu-pool m) prefix))
  (cond
    [(null? cands) (close-menu s)]
    [else
     (define idx (min (menu-idx m) (sub1 (length cands))))
     (define start (cons line (- col (string-length prefix))))
     (set-box! (c-svc-menu svc) (menu vid (menu-mvid m) (menu-did m) start cands idx (menu-pool m)))
     (session-ed-assign! s (menu-mvid m) (menu-doc cands idx))]))

(define (do-move s dir)
  (define svc (completion-svc s))
  (define m (unbox (c-svc-menu svc)))
  (define n (length (menu-cands m)))
  (define idx (modulo (+ (menu-idx m) dir) n))
  (set-box! (c-svc-menu svc) (struct-copy menu m [idx idx]))
  (session-ed-assign! s (menu-mvid m) (menu-doc (menu-cands m) idx)))

(define (do-accept s)
  (define m (unbox (c-svc-menu (completion-svc s))))
  (define cand (list-ref (menu-cands m) (menu-idx m)))
  (define vid (menu-vid m))
  (define line (session-view-point-line s vid))
  (define col (session-view-point-column s vid))
  (define start (menu-start m))
  (close-menu (session-ed-replace! s vid (car start) (cdr start) line col cand)))

(define (close-menu s)
  (define svc (completion-svc s))
  (define m (and svc (unbox (c-svc-menu svc))))
  (cond
    [(not m) s]
    [else
     (set-box! (c-svc-menu svc) #f)
     (define mvid (menu-mvid m))
     (define did (session-view-did s mvid))
     (define s1 (session-deco-remove (session-overlay-remove s mvid) 'complete))
     (session-close-document (session-layer-pop s1 'complete) did)]))

;;; ---------- 命令 + 键 + handler ----------

(define complete-keys
  (kbd (key 'down)   (cmd-complete-move 1)
       (key 'up)     (cmd-complete-move -1)
       (key 'tab)    (cmd-complete-accept)
       (key 'enter)  (cmd-complete-accept)
       (key 'escape) (cmd-complete-cancel)))

(define (completion-handler)
  (lambda (s cmd)
    (define svc (completion-svc s))
    (define open? (and svc (unbox (c-svc-menu svc)) #t))
    (cond
      [(and svc (cmd-complete? cmd)) (maybe-open s)]
      [(and open? (cmd-complete-move? cmd)) (do-move s (cmd-complete-move-dir cmd))]
      [(and open? (cmd-complete-accept? cmd)) (do-accept s)]
      [(and open? (cmd-complete-cancel? cmd)) (close-menu s)]
      [else #f])))

;; 改文本后：菜单已开 → 复用池刷新；否则尝试开（自动弹）。
;; 只跟「直接编辑」（after-insert），程序写入不触发。
(define (completion-refine-hook s _args)
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [(unbox (c-svc-menu svc)) (do-refine s)]
    [else (maybe-open s)]))

;; 焦点移开 → 取消菜单。
(define (completion-cancel-hook s _args)
  (define svc (completion-svc s))
  (if (and svc (unbox (c-svc-menu svc))) (close-menu s) s))

;; 菜单所属的编辑器文档关闭 → 取消菜单（避免叠加层悬空）。
(define (completion-doc-closed-hook s args)
  (define svc (completion-svc s))
  (define m (and svc (unbox (c-svc-menu svc))))
  (if (and m (eqv? (car args) (menu-did m))) (close-menu s) s))

;; before-render：轮询 worker，把到齐的结果交给闸门（session-deliver 会跑 on-result）。
(define (completion-poll-hook s _args)
  (define svc (completion-svc s))
  (define r (and svc (unbox (c-svc-runner svc))))
  (cond
    [(not r) s]
    [else
     (for/fold ([s s]) ([m (in-list (runner-poll! r))])
       (define res (cdr m))
       (if (job-result-ok? res)
           (session-deliver s (car m) (job-result-value res))
           s))]))

(define (completion-install s)
  (let* ([svc (c-svc (box #f) (box #f) (make-hash) (make-hash))]
         [s1 (session-service-put s 'complete svc)]
         [s2 (session-add-handler s1 (completion-handler))]
         [s3 (session-add-hook s2 (hook 'after-insert completion-refine-hook))]
         [s4 (session-add-hook s3 (hook 'focus-changed completion-cancel-hook))]
         [s5 (session-add-hook s4 (hook 'document-closed completion-doc-closed-hook))])
    (session-add-hook s5 (hook 'before-render completion-poll-hook))))

(define completion-spec
  (plugin-spec 'completion completion-install '()))
