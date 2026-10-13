#lang racket

;;; edit-rebuild/plugins/docs/main.rkt —— 文档窗插件（独立于补全）
;;;
;;; 把一个标识符的文档显示在一个可滚动的**浮窗**里：
;;;   · 浮窗贴在**源编辑窗格底部**、宽度取窗格宽（不顶起编辑区，不 reflow）；
;;;   · 高度随内容（外框 = 正文行 + 2 边框），有上界（min(18, 半屏)），超出就滚动；
;;;   · 正文按来源拼两段：本地定义（主线程同步扫打开的缓冲区）+ 标准库
;;;     （自己的 place worker）。任一段到了就**原地更新**窗口，不 hide / 不 reopen。
;;;   · 谁接键 / 谁在上层由会话的**浮层焦点栈**（core/session/overlay.rkt）统一决定：
;;;     栈头接键、抬到最上；Tab 在打开的浮层间轮换，Esc 关文档。
;;;
;;; 与补全只用一个事件解耦（两边不 require 对方）：
;;;   complete-selection  args = (vid name mods binding) | (vid #f #f #f)
;;;       binding = (list module original-name) | #f
;;;       候选名被 prefix-in / rename-in 改过时，按 (模块, 原名) 去查；
;;;       name = #f（菜单关闭）→ **补全结束，文档一并关**。

(require racket/list
         racket/match
         racket/path
         racket/string
         "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../../core/geometry/layout.rkt"
         "../lang/source.rkt"
         "../lang/pool.rkt"
         "../lang/local-docs.rkt"
         "../lang/docs.rkt"
         "job.rkt")

(provide docs-install docs-spec)

;;; ---------- 状态 ----------

(struct d-svc (ddid dvid q win local-cache rendered) #:transparent)
;; ddid      : did                    文档窗自己的 document（安装时建，长命）
;; dvid      : vid                    文档窗自己的 view
;; q         : box (#f | query)       当前查询（异步结果按 seq 落位）
;; win       : box (#f | docwin)      当前显示的正文 + 滚动 offset
;; local-cache : box (hash did -> (cons handle (hash name -> snippet)))
;; rendered  : box (#f | (cons lines face))  上次装进 view 的内容（内容没变就不重装）

(struct query (vid name mods binding seq local std) #:transparent)
;; local / std : string | #f   两段正文；显示顺序 = local 然后 std
;; seq         : nat           请求序号：只接受最新一次查询的结果

(struct docwin (vid lines offset seq) #:transparent)
;; vid    : 源编辑器视图（定位浮窗 / 本地定义上下文）
;; lines  : (listof string)   全部正文行（未折行，滚动用）
;; offset : nat               当前顶部行
;; seq    : nat               属于哪次查询（同一次查询的后续段保留滚动位置）

(define (docs-svc s) (session-service-ref s 'docs))
(define doc-max-rows 18)             ; 外框高度上界（实际取 min(此, 半屏)）
(define docs-base-deep 100)          ; 未接键：盖过编辑区（0），但低于补全（2000）

;; 视图还活着吗（关视图 / 换 buffer 后失效）。
(define (live-view? s vid) (and vid (memv vid (session-view-id-list s)) #t))

;;; ---------- 内容 / 几何 ----------

;; 外框高度上界（含上下边框）。
(define (doc-outer-max s)
  (max 3 (min doc-max-rows (quotient (session-height s) 2))))

;; 内容区行数上界 = 外框上界 - 2（上下边框）。
(define (doc-content-rows s)
  (max 1 (- (doc-outer-max s) 2)))

;; 当前可见的一段（按 offset / 内容行数上界切片）。
(define (doc-visible s dw)
  (define lines (docwin-lines dw))
  (define n (length lines))
  (define rows (min n (doc-content-rows s)))
  (define off (max 0 (min (docwin-offset dw) (max 0 (- n rows)))))
  (take (drop lines off) rows))

(define (doc-doc lines face)
  (panel-doc (for/list ([l (in-list lines)]) (list (string-append " " l) face))))

;; 正文 face / z 序：谁在浮层栈头（接键）谁亮、谁在上。
(define (doc-face s) (if (eq? (session-overlay-focus s) 'docs) 'docs 'docs-dim))
(define (docs-deep s) (overlay-deep s 'docs docs-base-deep))

;; 浮窗矩形：贴源编辑窗格底部、宽度取窗格宽。→ area | #f
(define (docs-pos s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) #f]
    [(not (live-view? s (docwin-vid dw))) #f]
    [else
     (define reg (session-view-region s (docwin-vid dw)))
     (cond
       [(not reg) #f]
       [else
        (define rows (length (doc-visible s dw)))
        (define h (min (doc-outer-max s) (+ rows 2)))
        (define y (max (area-y reg) (- (+ (area-y reg) (area-h reg)) h)))
        (and (positive? rows) (area (area-x reg) y (area-w reg) h))])]))

;; 面的 content：内容变了才返回新文档（否则 #f），交给 session-refresh 重装。
(define (docs-content s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) #f]
    [else
     (define lines (doc-visible s dw))
     (define face (doc-face s))
     (define sig (cons lines face))
     (cond
       [(equal? sig (unbox (d-svc-rendered svc))) #f]
       [else (set-box! (d-svc-rendered svc) sig) (doc-doc lines face)])]))

;;; ---------- 开 / 更新 / 关 ----------

;; 用当前 query 的两段拼正文，装进 win 并显示。没内容就保留旧窗（异步还没回）。
(define (docs-update! s)
  (define svc (docs-svc s))
  (define q (and svc (unbox (d-svc-q svc))))
  (cond
    [(not q) s]
    [else
     (define text (string-append (or (query-local q) "") (or (query-std q) "")))
     (cond
       [(zero? (string-length text)) s]
       [else
        (define vid (query-vid q))
        (cond
          [(not (live-view? s vid)) s]
          [else
           (define lines (string-split text "\n"))
           (define old (unbox (d-svc-win svc)))
           ;; 同一次查询的后续段（如标准库晚到）保留滚动位置；新查询回到顶部。
           (define off (if (and old (eqv? vid (docwin-vid old))
                                (= (query-seq q) (docwin-seq old)))
                           (docwin-offset old)
                           0))
           (set-box! (d-svc-win svc) (docwin vid lines off (query-seq q)))
           (define s1 (session-set-visible s (d-svc-dvid svc) #t))
           ;; 开窗：文档进浮层栈（栈空则自动接键；补全已接键则不抢）
           (session-overlay-open s1 'docs)])])]))

;; 关窗：清查询 / 显示，隐藏；并从浮层栈移除（焦点自然回落）。
(define (close-docs s)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (set-box! (d-svc-q svc) #f)
     (set-box! (d-svc-win svc) #f)
     (set-box! (d-svc-rendered svc) #f)
     (session-overlay-close (session-set-visible s (d-svc-dvid svc) #f) 'docs)]))

;; 本地文件模块：没有 scribble 文档，不启 worker。
(define (local-binding? binding)
  (and binding (let ([m (car binding)]) (or (path? m) (string? m)))))

;;; ---------- 查询 ----------

;; 按名字在打开的 Racket 缓冲区里找本地定义 → snippet | #f。
(define (local-text-for s name binding)
  (define sym (string->symbol name))
  (define (find did) (local-lookup s did sym))
  (cond
    ;; 来源模块是已打开的本地文件：只查它
    [(and binding (module-open-did s (car binding))) => find]
    ;; 否则：当前编辑文档 → 其它打开的 Racket 文档
    [else
     (define evid (session-edit-vid s))
     (define edid (and evid (session-view-did s evid)))
     (or (and edid (find edid))
         (for/or ([did (in-list (session-document-ids s))]
                  #:when (and (not (eqv? did edid))
                              (racket-file? (session-file-path s did))))
           (find did)))]))

(define (local-section s name binding)
  (define snippet (local-text-for s name binding))
  (and snippet (string-append "── 本地定义 ──\n" snippet "\n")))

;; 本地定义缓存：按文档版本（handle）分开。
(define (local-lookup s did sym)
  (define svc (docs-svc s))
  (define cache (unbox (d-svc-local-cache svc)))
  (define handle (session-document-handle s did))
  (define entry (hash-ref cache did #f))
  (define tbl
    (cond
      [(and entry (eq? (car entry) handle)) (cdr entry)]
      [else
       (define t (local-defs (session-document-string s did)))
       (hash-set! cache did (cons handle t))
       t]))
  (hash-ref tbl sym #f))

;; module spec（symbol / 路径字符串 / 路径）→ 若是**已打开的文档**则给出 did。
(define (module-open-did s mod)
  (define by-path
    (for/hash ([did (in-list (session-document-ids s))]
               #:when (session-file-path s did))
      (values (path->string (path->complete-path (session-file-path s did))) did)))
  (cond
    [(string? mod) (hash-ref by-path mod #f)]
    [(path? mod) (hash-ref by-path (path->string mod) #f)]
    [else #f]))

;; 标准库段：提交 worker 查询 + 版本闸门；回来原地补进当前查询。
(define (docs-request-std! s svc q)
  (define binding (query-binding q))
  (define qname (if binding (cadr binding) (query-name q)))
  (define qmods (if binding (list (car binding)) (query-mods q)))
  (define seq (query-seq q))
  (define id (doc-request! s (if (string? qname) qname (format "~a" qname)) qmods))
  (session-await s id seq
    (lambda (_s _tok)
      (define q* (unbox (d-svc-q svc)))
      (and q* (= seq (query-seq q*))))
    (lambda (s result)
      (define q* (unbox (d-svc-q svc)))
      (cond
        [(and q* (= seq (query-seq q*)))
         (define std (or (result->doc-text result) ""))
         (set-box! (d-svc-q svc) (struct-copy query q* [std std]))
         (cond
           [(and (zero? (string-length std)) (not (query-local q*))) (close-docs s)]
           [else (docs-update! s)])]
        [else s]))))

;; 发起一次查询（同一 name/mods/binding 不重复查）。
(define (docs-show! s vid name mods binding)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (define key (list name mods binding))
     (define q0 (unbox (d-svc-q svc)))
     (cond
       [(and q0 (equal? key (list (query-name q0) (query-mods q0) (query-binding q0)))) s]
       [else
        (define seq (add1 (if q0 (query-seq q0) 0)))
        ;; 本地定义按**原名**查（binding 把 prefix-in/rename-in 改过的名映射回去）。
        (define qname (if binding (cadr binding) name))
        (define local (local-section s qname binding))
        (set-box! (d-svc-q svc) (query vid name mods binding seq local #f))
        (cond
          [(local-binding? binding) (if local (docs-update! s) (close-docs s))]
          [else (docs-request-std! (docs-update! s) svc (unbox (d-svc-q svc)))])])]))

(define (result->doc-text r)
  (and (list? r)
       (= 3 (length r))
       (let ([sig (cadr r)] [body (caddr r)])
         (string-append (or sig "")
                        (if body (string-append (if sig "\n\n" "") body) "")
                        "\n"))))

;;; ---------- 事件 / 命令 ----------

;; 补全广播的选中项。菜单关闭（name=#f）→ 补全结束，文档一并关。
(define (docs-selection-hook s args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (match-define (list vid name mods binding) args)
     (cond
       [(or (not vid) (not name) (not (pair? mods))) (close-docs s)]
       [else (docs-show! s vid name mods binding)])]))

;; M-d：对光标处标识符独立查询（不依赖补全）。
(define (cmd-show-docs s)
  (define svc (docs-svc s))
  (define vid (session-focus-vid s))
  (cond
    [(or (not svc) (not vid) (session-dock-vid? s vid)) s]
    [(not (racket-file? (session-file-path s (session-view-did s vid)))) s]
    [else
     (define text (session-view-string s vid))
     (define id (identifier-at text (session-view-point-line s vid) (session-view-point-column s vid)))
     (cond
       [(not id) (close-docs s)]
       [else (docs-show! s vid id (cursor-mods s vid) (cursor-binding s vid id))])]))

;; 光标处标识符的来源（prefix-in/rename-in 反查）→ (list module original) | #f。
(define (cursor-binding s vid id)
  (define did (session-view-did s vid))
  (define path (session-file-path s did))
  (define text (session-view-string s vid))
  (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                       (current-directory)))
  (define-values (lang forms) (requires-context text))
  (spec-binding-of id (require-specs-of-forms lang forms) base-dir))

;; 光标处标识符所在文件的模块上下文（#lang + require；无则 racket/base）。
(define (cursor-mods s vid)
  (define did (session-view-did s vid))
  (define path (session-file-path s did))
  (define text (session-view-string s vid))
  (define base-dir (or (and path (let-values ([(d _f _m) (split-path path)]) d))
                       (current-directory)))
  (define-values (lang forms) (requires-context text))
  (define mods (requires-of-forms lang forms #:base-dir base-dir))
  (if (null? mods) '(racket/base) mods))

;; 鼠标点中文档窗 → 文档进栈头（抬起 + 接键）。
(define (docs-mouse s _vid _col _row)
  (define svc (docs-svc s))
  (cond
    [(and svc (unbox (d-svc-win svc))) (session-overlay-focus! s 'docs)]
    [else s]))

;; 焦点移开 / 光标导航（在编辑器里）→ 关窗。
(define (docs-cancel-hook s _args)
  (define svc (docs-svc s))
  (if (and svc (unbox (d-svc-win svc))) (close-docs s) s))

;; 文档窗自己的 document 被关（外部）→ 关窗；其它文档 → 清本地定义缓存。
(define (docs-doc-closed-hook s args)
  (define svc (docs-svc s))
  (define did (car args))
  (when svc (hash-remove! (unbox (d-svc-local-cache svc)) did))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(and dw (eqv? did (d-svc-ddid svc))) (close-docs s)]
    [else s]))

(define (docs-routes)
  (list (route* (command-pred cmd-docs-show?)
                (handler-effect (lambda (s _cmd) (values (cmd-show-docs s) 'handled)))
                #:priority 10)))

;;; ---------- 互动（声明式路由） ----------

;; 横向滚动：delta > 0 向右看。
(define (docs-hscroll! s delta)
  (define svc (docs-svc s))
  (cond
    [(not (and svc (unbox (d-svc-win svc)))) s]
    [else (session-ed-hscroll! s (d-svc-dvid svc) delta)]))

;; 纵向滚动：delta > 0 向下看。
(define (docs-scroll! s delta)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (define n (length (docwin-lines dw)))
     (define rows (min n (doc-content-rows s)))
     (define max-off (max 0 (- n rows)))
     (define off (max 0 (min max-off (+ (docwin-offset dw) delta))))
     (set-box! (d-svc-win svc) (struct-copy docwin dw [offset off]))
     s]))

;; Tab：在打开着的浮层间轮换接键（补全 ↔ 文档）。
(define (docs-interaction-routes)
  (list
   ;; Esc：文档接键时关窗（补全菜单已在自己的路由里处理 Esc）
   (route* (key 'escape)
           (session-effect (lambda (s) (values (close-docs s) 'handled)))
           #:when (scope-mode= 'overlay 'docs) #:priority 1400)
   ;; Tab：文档可见时切换接键态
   (route* (key 'tab)
           (session-effect (lambda (s) (values (session-overlay-cycle s) 'handled)))
           #:when (scope-visible 'docs) #:priority 1300)
   ;; 上下：文档接键时滚文档
   (route* (key 'up)   (session-effect (lambda (s) (values (docs-scroll! s -1) 'handled)))
           #:when (scope-mode= 'overlay 'docs) #:priority 1200)
   (route* (key 'down) (session-effect (lambda (s) (values (docs-scroll! s 1) 'handled)))
           #:when (scope-mode= 'overlay 'docs) #:priority 1200)
   ;; 左右：文档可见就一直滚文档（高优先于补全的“吞掉”）
   (route* (key 'left)  (session-effect (lambda (s) (values (docs-hscroll! s -5) 'handled)))
           #:when (scope-visible 'docs) #:priority 1100)
   (route* (key 'right) (session-effect (lambda (s) (values (docs-hscroll! s 5) 'handled)))
           #:when (scope-visible 'docs) #:priority 1100)))

;;; ---------- 注册 ----------

(define (docs-install s)
  ;; 常驻文档窗：安装时建好 document / view，登记为**浮面**（默认隐藏）。
  (define s0 (install-doc-job! s))
  (define-values (s1 ddid dvid)
    (session-add-document s0 "" (session-width s0) 1 #:name "*docs*"))
  (define svc (d-svc ddid dvid (box #f) (box #f) (box (make-hash)) (box #f)))
  (define sf (float-surface 'docs dvid docs-content
                            (float docs-pos docs-base-deep)
                            #f docs-mouse #f #f
                            #:border 'window-border #:deep docs-deep))
  (define s2 (session-set-visible (session-add-surface s1 sf) dvid #f))
  (let* ([s3 (session-service-put s2 'docs svc)]
         [s4 (for/fold ([s s3]) ([r (in-list (docs-routes))]) (session-add-route s r))]
         [s5 (session-add-hook s4 (reaction 'complete-selection docs-selection-hook))]
         [s6 (for/fold ([s s5]) ([r (in-list (docs-interaction-routes))])
               (session-add-route s r))]
         [s7 (session-add-hook s6 (reaction 'focus-changed docs-cancel-hook
                                            #:when (scope-focus-kind 'editor)))]
         [s8 (session-add-hook s7 (reaction 'after-nav docs-cancel-hook
                                            #:when (scope-focus-kind 'editor)))])
    (session-add-hook s8 (reaction 'document-closed docs-doc-closed-hook))))

(define docs-spec
  (plugin-spec 'docs docs-install '()))
