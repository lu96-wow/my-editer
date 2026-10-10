#lang racket

;;; edit-rebuild/plugins/completion/main.rkt —— 补全插件（模块路径 / 模块导出 / 本地定义 / 文档词）
;;;
;;; 只做补全菜单（候选），不认识文档：文档浮窗是另一个插件（plugin/builtin/docs.rkt）。
;;; 两窗通过一个**事件**解耦：本插件在选中项变化时广播 `complete-selection`，
;;; 文档插件订阅后自己去异步查文档。补全不等文档就绪。
;;;
;;; 菜单是一个 **float 面（surface）**（不抢焦点）；打开时随面压一个输入层（模态键表）：
;;;   · 上下/Enter/Tab/Esc 由层接管；
;;;   · 普通字符层里没有 → fallthrough 到文档键表 → cmd-insert → 本 handler 接手：
;;;     先插入再按新前缀从**复用池**过滤。
;;; 接受：把 [前缀起点, 光标) 换成候选。
;;;
;;; 慢部分（已安装模块路径 / module->exports）丢给 `plugin/runner.rkt` 的 place worker：
;;;   · 池按「上下文键」缓存（'module / (exports . mods)）；
;;;   · 未缓存 → 提交请求 + `session-await` 闸门；结果由 before-render 轮询取回并装池；
;;;   · 到齐后 `maybe-open` 按当前光标上下文重新判断 → 开菜单（或再请求下一键）。
;;; 本地信息（文档词 / 顶层定义 / require 解析）留主线程（快）；其中「文档词」
;;; 用每文档**增量词表**（lang/word-index），after-edit 只重扫改动行。

(require racket/list
         racket/path
         racket/runtime-path
         racket/string
         "../../core/async/runner.rkt"
         "../../core/extension/spec.rkt"
         "../../core/extension/api.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../../core/geometry/popup.rkt"
         "../../core/geometry/layout.rkt"
         "../lang/source.rkt"
         "../lang/module-index.rkt"
         "../lang/pool.rkt"
         "../lang/word-index.rkt")

(provide completion-install completion-spec)

;;; ---------- 服务状态 ----------

(struct c-svc (menu runner cache pending parse words wdocs active docs-open?) #:transparent)
;; menu    : box (menu | #f)      补全菜单浮窗
;; runner  : box (runner | #f)    惰性创建（place 只能在 with-tui 之后建）
;; cache   : hash 上下文键 -> (listof string)   模块路径 / 导出名
;; pending : hash 上下文键 -> #t                已提交、未回来
;; parse   : hash did -> parse-entry            头部（#lang/require/定义）解析缓存
;; words   : hash did -> wi                    每文档增量词表
;; wdocs   : hash did -> handle                词表所反映的文档版本
;; active  : box 'complete | 'docs              当前接键的浮窗
;; docs-open? : box boolean                     文档窗是否开着（由 docs 插件广播）

(struct menu (vid mvid did start cands idx pool mods) #:transparent)
;; vid    : 编辑器 view（发起补全者，接受时改它 / 取光标锚点）
;; mvid   : 菜单视图
;; did    : 发起时编辑器文档 id（关文档时以此取消菜单）
;; start  : (cons line col)  前缀起点
;; cands  : (listof string)  当前过滤后的候选
;; idx    : 选中下标
;; pool   : (listof string)  本次会话的完整候选池（复用）
;; mods   : (listof module-path) | #f   候选所属模块（广播给订阅者；#f = 模块路径）

;; 补全上下文：决定池从哪来、缓存键是什么。
(struct ctx (key locals words mods) #:transparent)
;; key    : 'module | (list 'exports mods) | #f    #f = 只需文档词（同步，无需 worker）
;; locals : (listof symbol)   文件顶层定义名
;; words  : (listof string)   文件里出现过的词
;; mods   : (listof module-path) | #f   候选所属模块

;; 头部解析缓存项：签名 + 模块表 + 顶层定义名。
(struct parse-entry (sig mods locals) #:transparent)

(define (completion-svc s) (session-service-ref s 'complete))
(define max-rows 10)
(define menu-deep 2000)                            ; 远高于布局树
(define header-lines 200)                          ; 缓存签名只看前 N 行

;; 源视图还活着吗（关视图 / 换 buffer 后浮窗要失效）。
(define (live-view? s vid) (and vid (memv vid (session-view-id-list s)) #t))

;;; ---------- 上下文 / 池 ----------

;; 前 N 行的文本作为头部签名（require / 定义都在文件头部）。
(define (header-sig text)
  (define lines (string-split text "\n" #:trim? #f))
  (string-join (take lines (min header-lines (length lines))) "\n"))

;; 头部解析（按 did 缓存；签名不变则复用）。→ parse-entry
(define (parse-for svc did text path)
  (define sig (header-sig text))
  (define old (hash-ref (c-svc-parse svc) did #f))
  (cond
    [(and old (equal? sig (parse-entry-sig old))) old]
    [else
     (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                          (current-directory)))
     (define-values (lang forms) (requires-context text))
     (define e (parse-entry sig
                            (requires-of-forms lang forms #:base-dir base-dir)
                            (definitions-of-forms forms)))
     (hash-set! (c-svc-parse svc) did e)
     e]))

;; 每 did 的增量词表（首次 / 版本不符 → 整篇建）。
(define (word-index-for s svc did text)
  (define w (hash-ref (c-svc-words svc) did #f))
  (define cur (session-document-handle s did))
  (cond
    [(and w (eq? (hash-ref (c-svc-wdocs svc) did #f) cur)) w]
    [else
     (define w* (word-index-open text))
     (hash-set! (c-svc-words svc) did w*)
     (hash-set! (c-svc-wdocs svc) did cur)
     w*]))

(define (make-ctx s svc vid text line col)
  (cond
    [(require-context? text line col) (ctx 'module '() '() #f)]
    [else
     (define did (session-view-did s vid))
     (define path (and did (session-file-path s did)))
     (define words (word-index-words (word-index-for s svc did text)))
     (cond
       [(not (racket-file? path)) (ctx #f '() words '())]
       [else
        (define e (parse-for svc did text path))
        ;; 无 require / 无语言 → 以 racket/base 作基线（与 lab-rebuild 一致）
        (define mods (let ([m (parse-entry-mods e)]) (if (null? m) '(racket/base) m)))
        (ctx (list 'exports mods)
             (parse-entry-locals e)
             words
             mods)])]))

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

(define-runtime-path worker-path "worker.rkt")

(define (ensure-runner svc)
  (or (unbox (c-svc-runner svc))
      (let ([r (make-place-runner worker-path 'main #:wake async-wake)])
        (set-box! (c-svc-runner svc) r)
        r)))

;; 请求键 → worker 请求。'module → (module-paths)；(exports . mods) → 自身。
(define (ctx-request key)
  (if (eq? key 'module) '(module-paths) key))

;;; ---------- 选中项事件（解耦：文档插件订阅） ----------

;; 广播当前选中候选。菜单开 → (vid name mods menu-rect)；关 → (vid #f #f #f)。
;; 发完即返回，不等任何异步（补全与文档互不阻塞）。
(define (publish-selection! s m)
  (cond
    [(or (not m) (not (live-view? s (menu-vid m))))
     (session-run-hooks s 'complete-selection (list (session-focus-vid s) #f #f #f))]
    [else
     (define-values (_start _rows x y w h) (menu-layout s m))
     (session-run-hooks s 'complete-selection
                        (list (menu-vid m)
                              (list-ref (menu-cands m) (menu-idx m))
                              (menu-mods m)
                              (list x y w h)))]))

;;; ---------- 菜单内容 / 几何 ----------

;; 菜单外框宽度：内容宽(+2) + 左右边框(2)。钳到屏幕内。
(define (menu-width s m)
  (define base (+ 4 (for/fold ([mx 0]) ([x (in-list (menu-cands m))]) (max mx (string-length x)))))
  (min (max 12 (- (session-width s) 2)) (max 12 base)))

;; 菜单完整布局：候选窗口 + 矩形（落位规则见 geometry/popup.rkt）。
;; → (values start rows x y w h)
(define (menu-layout s m)
  (define-values (col row) (session-view-cursor-screen s (menu-vid m)))
  (define c (or col 0))
  (define r (or row 0))
  (define sw (session-width s))
  (define sh (session-height s))
  (define cands (menu-cands m))
  (define w (menu-width s m))
  ;; 行数上界：外框高 = 候选行 + 2（上下边框），不能遮住光标行
  (define cap (max 1 (min max-rows (length cands) (max 1 (- (popup-max-h r sh) 2)))))
  (define-values (start rows) (popup-window (length cands) (menu-idx m) cap))
  (define-values (x y w* h) (popup-rect r c w (+ rows 2) sw sh))
  (values start rows x y w* h))

;; 菜单文档：候选行（选中高亮）。
(define (menu-doc cands idx start rows)
  (define shown (take (drop cands start) rows))
  ;; 整行铺满（含尾部空白）→ 弹窗整体有淡灰底，不只剩文字处有色
  (define w (+ 2 (for/fold ([mx 0]) ([c (in-list cands)]) (max mx (string-length c)))))
  (panel-doc
   (for/list ([c (in-list shown)] [i (in-naturals)])
     (define line (string-append " " c))
     (list (string-append line (make-string (max 0 (- w (string-length line))) #\space))
           (if (= (+ start i) idx) 'complete-selected 'complete)))))

;; 按当前菜单状态重装菜单文档。
(define (refresh-menu-doc! s)
  (define svc (completion-svc s))
  (define m (unbox (c-svc-menu svc)))
  (cond
    [(not m) s]
    [else
     (define-values (start rows _x _y _w _h) (menu-layout s m))
     (session-ed-assign! s (menu-mvid m) (menu-doc (menu-cands m) (menu-idx m) start rows))]))

;; 每帧浮面落位：菜单开着、源视图还在、光标在视口内才显示。→ (list x y w h) | #f
(define (menu-pos s)
  (define svc (completion-svc s))
  (define m (and svc (unbox (c-svc-menu svc))))
  (cond
    [(not m) #f]
    [(not (live-view? s (menu-vid m))) #f]          ; 源视图没了 → 不摆
    [else
     (define-values (col _row) (session-view-cursor-screen s (menu-vid m)))
     (cond
       [(not col) #f]                               ; 光标不在视口 → 不摆
       [else
        (define-values (_start _rows x y w h) (menu-layout s m))
        (and (positive? h) (area x y w h))])]))

;;; ---------- 打开 / 刷新 / 移动 / 接受 / 关闭 ----------

(define (open-menu! s vid line col prefix pool mods)
  (define cands (filter-pool pool prefix))
  (cond
    [(null? cands) s]
    [else
     (define svc (completion-svc s))
     (define start (cons line (- col (string-length prefix))))
     (define m0 (menu vid #f (session-view-did s vid) start cands 0 pool mods))
     (define-values (_start rows _x _y w h) (menu-layout s m0))
     (define-values (s1 _mdid mvid)
       (session-add-document s (menu-doc cands 0 0 rows) w h #:name "*complete*"))
     (define m (struct-copy menu m0 [mvid mvid]))
     (set-box! (c-svc-menu svc) m)
     (set-box! (c-svc-active svc) 'complete)     ; 默认接键的是补全
     ;; 浮面：每帧按 menu-pos 落位 + overlay 标记（dock / 不入缓冲区）+ 压输入层（complete-keys）
     (define s2 (session-add-surface s1
                  (float-surface 'complete mvid #f
                                 (float menu-pos menu-deep)
                                 complete-keys #f #f #f
                                 #:border 'window-border)))
     (publish-selection! (refresh-menu-doc! s2) m)]))

;; 补全只在「主区编辑视图」上启用（面板 / 叠加层 / 补全菜单自身不弹）。
(define (completable? s vid)
  (and vid (not (session-dock-vid? s vid))))

;; 按当前光标：缓存命中就开菜单；否则提交异步请求。
(define (maybe-open s)
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [(unbox (c-svc-menu svc)) s]
    [else
     (define vid (session-focus-vid s))
     (cond
       [(not (completable? s vid)) s]
       [else
        (define text (session-view-string s vid))
        (define line (session-view-point-line s vid))
        (define col (session-view-point-column s vid))
        (define prefix (prefix-at text line col))
        (cond
          [(zero? (string-length prefix)) s]
          [else
           (define ctx (make-ctx s svc vid text line col))
           (cond
             [(ctx-cached? svc ctx) (open-menu! s vid line col prefix (ctx-pool svc ctx) (ctx-mods ctx))]
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
  (cond
    [(not (live-view? s (menu-vid m))) (close-menu s)]   ; 源视图没了 → 关
    [else
     (define vid (menu-vid m))
     (define text (session-view-string s vid))
     (define line (session-view-point-line s vid))
     (define col (session-view-point-column s vid))
     (define prefix (prefix-at text line col))
     (cond
       ;; 前缀被删空（词删完）→ 关菜单
       [(zero? (string-length prefix)) (close-menu s)]
       [else
        (define cands (filter-pool (menu-pool m) prefix))
        (cond
          [(null? cands) (close-menu s)]
          [else
           (define idx (min (menu-idx m) (sub1 (length cands))))
           (define start (cons line (- col (string-length prefix))))
           (set-box! (c-svc-menu svc)
                     (struct-copy menu m [start start] [cands cands] [idx idx]))
           (publish-selection! (refresh-menu-doc! s) (unbox (c-svc-menu svc)))])])]))

(define (do-move s dir)
  (define svc (completion-svc s))
  (define m (unbox (c-svc-menu svc)))
  (define n (length (menu-cands m)))
  (define idx (modulo (+ (menu-idx m) dir) n))
  (set-box! (c-svc-menu svc) (struct-copy menu m [idx idx]))
  (publish-selection! (refresh-menu-doc! s) (unbox (c-svc-menu svc))))

(define (do-accept s)
  (define m (unbox (c-svc-menu (completion-svc s))))
  (cond
    [(not (live-view? s (menu-vid m))) (close-menu s)]   ; 源视图没了 → 关
    [else
     (define cand (list-ref (menu-cands m) (menu-idx m)))
     (define vid (menu-vid m))
     (define line (session-view-point-line s vid))
     (define col (session-view-point-column s vid))
     (define start (menu-start m))
     (close-menu (session-ed-replace! s vid (car start) (cdr start) line col cand))]))

;; 关补全菜单，并广播「无选中」。
(define (close-menu s)
  (define svc (completion-svc s))
  (define m (unbox (c-svc-menu svc)))
  (cond
    [(not m) s]
    [else
     (set-box! (c-svc-menu svc) #f)
     (define mvid (menu-mvid m))
     (define did (session-view-did s mvid))
     (define s1 (session-remove-surface s 'complete))
     (define s2 (session-close-document s1 did))
     (set-box! (c-svc-active svc) 'complete)
     (publish-selection! s2 #f)]))

;;; ---------- 命令 + 键 + handler ----------

(define complete-keys
  (kbd (key 'down)   (cmd-complete-move 1)
       (key 'up)     (cmd-complete-move -1)
       (key 'right)  (cmd-complete-scroll 5)     ; 文档窗向下看 5 行
       (key 'left)   (cmd-complete-scroll -5)
       (key 'tab)    (cmd-complete-switch)       ; 补全 ↔ 文档
       (key 'enter)  (cmd-complete-accept)
       (key 'escape) (cmd-complete-cancel)))

(define (completion-handler)
  (lambda (s cmd)
    (define svc (completion-svc s))
    (define open? (and svc (unbox (c-svc-menu svc)) #t))
    (cond
      [(and svc (cmd-complete? cmd)) (maybe-open s)]
      ;; Tab：有文档窗时在补全 / 文档之间切换接键；没有则不动。
      [(and open? (cmd-complete-switch? cmd))
       (cond
         [(not (unbox (c-svc-docs-open? svc))) s]
         [else
          (define active (if (eq? (unbox (c-svc-active svc)) 'complete) 'docs 'complete))
          (set-box! (c-svc-active svc) active)
          (session-run-hooks s 'docs-focus (list (eq? active 'docs)))])]
      ;; 上/下：补全接键 → 移候选；文档接键 → 滚文档。
      [(and open? (cmd-complete-move? cmd))
       (if (eq? (unbox (c-svc-active svc)) 'complete)
           (do-move s (cmd-complete-move-dir cmd))
           (session-run-hooks s 'docs-scroll (list (cmd-complete-move-dir cmd))))]
      ;; 左/右：不管谁接键都滚文档（便于边看文档边选）。
      [(and open? (cmd-complete-scroll? cmd))
       (session-run-hooks s 'docs-scroll (list (cmd-complete-scroll-delta cmd)))]
      [(and open? (cmd-complete-accept? cmd)) (do-accept s)]
      [(and open? (cmd-complete-cancel? cmd)) (close-menu s)]
      [else #f])))

;; docs 插件广播的开关状态（供 Tab 判断 / 关闭时复位）。
(define (completion-docs-state-hook s args)
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [else
     (define open? (car args))
     (set-box! (c-svc-docs-open? svc) open?)
     (unless open? (set-box! (c-svc-active svc) 'complete))
     s]))

;; 改文本后：菜单已开 → 复用池刷新；否则尝试开（自动弹）。
;; 只跟「直接编辑」（after-insert），程序写入不触发。
(define (completion-refine-hook s _args)
  (define svc (completion-svc s))
  (define vid (session-focus-vid s))
  (cond
    [(or (not svc) (not (completable? s vid)))
     (if (and svc (unbox (c-svc-menu svc))) (close-menu s) s)]
    [(unbox (c-svc-menu svc)) (do-refine s)]
    [else (maybe-open s)]))

;; after-edit：把一次编辑的 changes 增量喂给该 did 的增量词表（没有词表就跳过，
;; 首次用时才整篇建）。坐标越界 / 版本异常由 before-render 的版本校验兜底重建。
(define (word-note-hook s args)
  (define vid (car args))
  (define changes (cadr args))
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [else
     (define did (session-view-did s vid))
     (define w (hash-ref (c-svc-words svc) did #f))
     (cond
       [(not w) s]
       [else
        (define w* (word-index-update w changes (session-document-track s did)))
        (hash-set! (c-svc-words svc) did w*)
        (hash-set! (c-svc-wdocs svc) did (session-document-handle s did))
        s])]))

;; before-render：程序写入（assign）/ undo 不过 after-edit，会让词表与文档脱节；
;; 这里对每个已建词表的 did 校版本，换了就整篇重建。
(define (word-resync-hook s _args)
  (define svc (completion-svc s))
  (cond
    [(not svc) s]
    [else
     (define live (session-document-ids s))
     (define tbl (c-svc-words svc))
     (define wdocs (c-svc-wdocs svc))
     ;; 防御：直接关文档而没走 document-closed 的路径，清掉死 did
     (for ([did (in-list (hash-keys tbl))] #:unless (memv did live))
       (hash-remove! tbl did)
       (hash-remove! wdocs did))
     (for ([did (in-list (hash-keys tbl))])
       (unless (eq? (hash-ref wdocs did #f) (session-document-handle s did))
         (hash-set! tbl did (word-index-open (session-document-string s did)))
         (hash-set! wdocs did (session-document-handle s did))))
     s]))

;; 焦点移开 / 光标导航 → 取消菜单（否则候选与前缀错位）。
(define (completion-cancel-hook s _args)
  (define svc (completion-svc s))
  (if (and svc (unbox (c-svc-menu svc))) (close-menu s) s))

;; 菜单所属的编辑器文档关闭 → 取消菜单 + 清头部 / 词表缓存。
(define (completion-doc-closed-hook s args)
  (define svc (completion-svc s))
  (define did (car args))
  (when svc
    (hash-remove! (c-svc-parse svc) did)
    (hash-remove! (c-svc-words svc) did)
    (hash-remove! (c-svc-wdocs svc) did))
  (define m (and svc (unbox (c-svc-menu svc))))
  (if (and m (eqv? did (menu-did m))) (close-menu s) s))

;; before-render：轮询 worker，把到齐的结果交给闸门（session-deliver 会跑 on-result）。
(define (completion-poll-hook s _args)
  (define svc (completion-svc s))
  (define r (and svc (unbox (c-svc-runner svc))))
  (cond
    [(not r) s]
    [else
     (for/fold ([s s]) ([m (in-list (runner-poll! r))])
       (define res (cdr m))
       (cond
         [(job-result-ok? res) (session-deliver s (car m) (job-result-value res))]
         ;; worker 出错：记日志，并以空值交付（清 pending + 不重试）。
         [else (session-deliver (session-log! s (format "complete worker: ~a" (job-result-value res)))
                                (car m) '())]))]))

(define (completion-install s)
  (let* ([svc (c-svc (box #f) (box #f) (make-hash) (make-hash) (make-hash)
                     (make-hash) (make-hash) (box 'complete) (box #f))]
         [s1 (session-service-put s 'complete svc)]
         [s2 (session-add-handler s1 (completion-handler))]
         [s3 (session-add-hook s2 (hook 'after-edit word-note-hook))]
         [s4 (session-add-hook s3 (hook 'after-insert completion-refine-hook))]
         [s5 (session-add-hook s4 (hook 'focus-changed completion-cancel-hook))]
         [s6 (session-add-hook s5 (hook 'after-nav completion-cancel-hook))]
         [s7 (session-add-hook s6 (hook 'document-closed completion-doc-closed-hook))]
         [s8 (session-add-hook s7 (hook 'before-render completion-poll-hook))]
         [s9 (session-add-hook s8 (hook 'before-render word-resync-hook))])
    (session-add-hook s9 (hook 'docs-state completion-docs-state-hook))))

(define completion-spec
  (plugin-spec 'completion completion-install '()))
