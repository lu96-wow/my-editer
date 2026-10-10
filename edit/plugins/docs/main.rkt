#lang racket

;;; edit-rebuild/plugins/docs/main.rkt —— 文档窗插件（独立于补全）
;;;
;;; 只负责「把某个标识符的文档显示在一个可滚动的**底部窗口**里」，不认识补全：
;;;   · 订阅补全发布的 `complete-selection`（选中项变化 → 查它的文档）；
;;;   · 也可用命令 `cmd-docs-show`（M-d）对**光标处标识符**独立查询；
;;;   · 异步走 doc-job（自己的 place worker / 闸门），从不等补全 / 不阻塞；
;;;   · 文档窗是一个 **dock 面（surface）**，落在编辑区底部专用区 slot-docs（状态行
;;;     上方）：出现时顶起编辑区，状态行仍在最底，且横跨编辑区宽（不再是浮窗）；
;;;   · 窗口高度随内容（外框高 = 正文行 + 2 边框），有上界，超出就滚动。
;;;
;;; 与补全的事件契约（两边都不 require 对方）：
;;;   complete-selection  args = (vid name mods binding menu-rect) | (vid #f #f #f #f)
;;;       binding = (list module original-name) | #f —— 候选名被 prefix-in/rename-in 改过时，
;;;       按原名去模块里查（对应 racket-langserver 用 check-syntax 得到的 (path, def-tag)）。
;;;       doc 订阅：新选中 → 查文档；#f → 关窗
;;;   docs-state          args = (open?)        doc 广播：文档窗开关（补全据此决定 Tab 是否切换）
;;;   docs-scroll         args = (delta)       doc 订阅：竖直滚动 delta 行
;;;   docs-hscroll        args = (delta)       doc 订阅：水平滚动 delta 列
;;;   docs-focus          args = (active?)      doc 订阅：是否接键（决定正文亮/暗）

(require racket/list
         racket/match
         racket/path
         racket/string
         "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../lang/source.rkt"
         "../lang/pool.rkt"
         "../lang/local-docs.rkt"
         "../lang/docs.rkt"
         "job.rkt")

(provide docs-install docs-spec)

;;; ---------- 状态 ----------

(struct d-svc (ddid dvid win seq last-key pending focus cur std-text phase local-cache)
  #:transparent)
;; ddid      : did                    文档窗自己的 document（安装时建，长命）
;; dvid      : vid                    文档窗自己的 view（dock 面，常驻）
;; win       : box ((docwin | #f))    当前显示的文档（#f = 关着）
;; seq       : box integer            请求序号（判定迟到结果）
;; last-key  : box any/c              上次已查询的键（name+mods），避免重复请求
;; pending   : box ((list vid name mods binding) | #f)  待处理选中项（本帧内只记，不做事）
;; focus     : box boolean            是否接键（Tab 切过来时高亮）
;; cur       : box ((list vid name binding) | #f)  当前查询（本地定义阶段用）
;; std-text  : box (#f | string)      标准库正文（#f = worker 还没回来）
;; phase     : box 'idle | 'wait-std | 'show-local
;; local-cache : box (hash did -> (cons handle (hash name -> snippet)))  本地定义缓存（按文档版本）

(struct docwin (vid text lines offset) #:transparent)
;; vid    : 源编辑器视图（本地定义上下文用）
;; text   : string            原始正文（未折行）
;; lines  : (listof string)   全部显示行（未折行，滚动用）
;; offset : nat               当前顶部行

(define (docs-svc s) (session-service-ref s 'docs))
(define doc-max-rows 18)            ; 窗口**外框**高度上界（实际取 min(此, 半屏)）

;; 视图还活着吗（关视图 / 换 buffer 后失效）。
(define (live-view? s vid) (and vid (memv vid (session-view-id-list s)) #t))

;;; ---------- 窗口内容 / 几何 ----------

;; 窗口外框高度上界（含上下边框）。
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

(define (doc-face svc) (if (unbox (d-svc-focus svc)) 'docs 'docs-dim))

;; 重装文档文档（滚动 / 焦点变化后）。
(define (refresh-doc-window! s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (session-ed-assign! s (d-svc-dvid svc) (doc-doc (doc-visible s dw) (doc-face svc)))]))

;;; ---------- 开 / 关 ----------

;; 关文档窗（隐藏底部文档区；document / view 常驻不关）。广播 docs-state #f。
(define (remove-doc-window! s)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (set-box! (d-svc-win svc) #f)
     (session-run-hooks (session-set-visible s (d-svc-dvid svc) #f)
                        'docs-state (list #f))]))

(define (bump-seq! svc) (set-box! (d-svc-seq svc) (add1 (unbox (d-svc-seq svc)))))

;; 关文档窗（并使在途结果失效）。
(define (close-docs s)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (bump-seq! svc)
     (set-box! (d-svc-phase svc) 'idle)
     (set-box! (d-svc-std-text svc) #f)
     (set-box! (d-svc-cur svc) #f)
     (remove-doc-window! s)]))

;; 打开 / 更新文档窗（保证单实例）。开窗后广播 docs-state #t。
(define (open-window! s svc vid text)
  (define all (string-split text "\n"))   ; 不折行：bluebox 是对齐文本；超宽用 left/right 横向看
  (cond
    [(null? all) s]
    [else
     (define rows (min (length all) (doc-content-rows s)))
     (define dw (docwin vid text all 0))
     (set-box! (d-svc-win svc) dw)
     (define s1 (session-ed-assign! s (d-svc-dvid svc)
                                    (doc-doc (doc-visible s dw) (doc-face svc))))
     (define s2 (session-set-visible s1 (d-svc-dvid svc) #t))
     ;; 外框高 = 内容行 + 2（上下边框）；出现时顶起编辑区（状态行仍在最底）。
     (session-run-hooks (session-panel-fit! s2 'docs (+ rows 2)) 'docs-state (list #t))]))

;; 把本地定义段放到窗口**顶部**（标准库在下、先开；本地后到就 prepend 到顶部，保证可见）。
(define (prepend-doc-window! s extra)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (define text (string-append extra
                                 (if (string-suffix? extra "\n") "" "\n")
                                 (docwin-text dw)))
     (open-window! s svc (docwin-vid dw) text)]))

(define (result->doc-text r)
  (and (list? r)
       (= 3 (length r))
       (let ([sig (cadr r)] [body (caddr r)])
         (string-append (or sig "")
                        (if body (string-append (if sig "\n\n" "") body) "")
                        "\n"))))

;; 第一步：提交标准库查询（worker + 长命缓存），结果存 std-text，等 tick 开窗。
;; name 已是**原名**（binding 非 #f 时）；binding 留给第二步查本地定义。
(define (start-std! s svc vid name binding mods)
  (bump-seq! svc)
  (define seq (unbox (d-svc-seq svc)))
  (set-box! (d-svc-cur svc) (list vid name binding))
  (set-box! (d-svc-std-text svc) #f)
  (set-box! (d-svc-phase svc) 'wait-std)
  (define s1 (remove-doc-window! s))
  ;; 本地文件模块没有 scribble 文档：不启 worker（xref 首次加载很慢），直接空标准库进第二步。
  (cond
    [(and binding (let ([m (car binding)]) (or (path? m) (string? m))))
     (set-box! (d-svc-std-text svc) "")
     s1]
    [else
     (define id (doc-request! s1 (if (string? name) name (format "~a" name)) mods))
     (session-await s1 id seq
       (lambda (_s tok) (= tok (unbox (d-svc-seq svc))))
       (lambda (s result)
         (cond
           [(= seq (unbox (d-svc-seq svc)))
            (set-box! (d-svc-std-text svc) (or (result->doc-text result) ""))
            s]
           [else s])))]))

;; 第二步：本地定义。主线程扫打开的 Racket 缓冲区；缓存按文档版本（handle）分开。
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

;; 已打开的文档里找 name 定义 → 一段文本 | #f；binding 用来把 prefix-in/rename-in 后的
;; 名字映射回原模块 + 原名（标准库模块不掺本地定义）。
(define (local-text-for s name binding)
  (define sym (string->symbol name))
  (define (section did)
    (define snippet (local-lookup s did sym))
    (and snippet (string-append "── 本地定义 ──\n" snippet "\n")))
  (cond
    ;; 来源模块是已打开的本地文件：只查它（原名）
    [(and binding (module-open-did s (car binding)))
     => (lambda (bdid) (section bdid))]
    ;; 否则（标准库模块 / 无来源 / 当前文件自己的定义）：查当前编辑文档，再退到其它打开的 Racket 文档
    [else
     (define evid (session-edit-vid s))
     (define edid (and evid (session-view-did s evid)))
     (or (and edid (section edid))
         (for/or ([did (in-list (session-document-ids s))]
                  #:when (and (not (eqv? did edid))
                              (racket-file? (session-file-path s did))))
           (section did)))]))

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

;;; ---------- 事件 / 命令 ----------

;; 补全广播的选中项变化。新选中只记不做（O(1)，补全不等文档）；
;; 「无选中」（菜单关闭）则**立即**关窗（不涉及异步，不等）。
(define (docs-selection-hook s args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (match-define (list vid name mods binding _menu-rect) args)
     (cond
       [(or (not vid) (not name))
        (set-box! (d-svc-pending svc) #f)
        (set-box! (d-svc-last-key svc) #f)
        (close-docs s)]
       [else
        (set-box! (d-svc-pending svc) (list vid name mods binding))
        s])]))

;; before-render：两步走 —— 先开标准库窗（快），下一拍再追加本地定义。
(define (docs-tick-hook s _args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else
     (define p (unbox (d-svc-pending svc)))
     (cond
       ;; 新选中项：提交标准库查询（第一步），进入 wait-std
       [p
        (set-box! (d-svc-pending svc) #f)
        (match-define (list vid name mods binding) p)
        (cond
          [(or (not vid) (not name) (not (pair? mods)))
           (set-box! (d-svc-last-key svc) #f)
           (set-box! (d-svc-phase svc) 'idle)
           (close-docs s)]
          [(equal? (list name mods) (unbox (d-svc-last-key svc))) s]
          [else
           (set-box! (d-svc-last-key svc) (list name mods))
           ;; 候选名 → (模块, 原名)：标准库与本地定义都查原名
           (define qname (if binding (cadr binding) name))
           (define qmods (if binding (list (car binding)) mods))
           (start-std! s svc vid qname binding qmods)])]
       [else
        (case (unbox (d-svc-phase svc))
          ;; 第一步：标准库回来 → 先只开标准库
          [(wait-std)
           (define t (unbox (d-svc-std-text svc)))
           (cond
             [(not t) s]
             [else
              (set-box! (d-svc-phase svc) 'show-local)
              (define cur (unbox (d-svc-cur svc)))
              (cond
                [(and cur (positive? (string-length t)) (live-view? s (car cur)))
                 (open-window! s svc (car cur) t)]
                [else s])])]
          ;; 第二步：本地定义 → 追加（标准库为空时直接用它开窗）
          [(show-local)
           (set-box! (d-svc-phase svc) 'idle)
           (define cur (unbox (d-svc-cur svc)))
           (cond
             [(not cur) s]
             [else
              (define extra (local-text-for s (cadr cur) (caddr cur)))
              (cond
                [(not extra) s]
                [(unbox (d-svc-win svc)) (prepend-doc-window! s extra)]
                [(live-view? s (car cur)) (open-window! s svc (car cur) extra)]
                [else s])])]
          [else s])])]))

;; 横向滚动：delta > 0 向右看（移动视口 left-column）。
(define (docs-hscroll-hook s args)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else (session-ed-hscroll! s (d-svc-dvid svc) (car args))]))

;; 纵向滚动：delta > 0 向下看。
(define (docs-scroll-hook s args)
  (define svc (docs-svc s))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(not dw) s]
    [else
     (define delta (car args))
     (define n (length (docwin-lines dw)))
     (define rows (min n (doc-content-rows s)))
     (define max-off (max 0 (- n rows)))
     (define off (max 0 (min max-off (+ (docwin-offset dw) delta))))
     (set-box! (d-svc-win svc) (struct-copy docwin dw [offset off]))
     (refresh-doc-window! s)]))

;; Tab 切过来/切走：只改高亮（亮 / 暗）。
(define (docs-focus-hook s args)
  (define svc (docs-svc s))
  (cond
    [(not svc) s]
    [else (set-box! (d-svc-focus svc) (car args)) (refresh-doc-window! s)]))

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
       [(not id) (set-box! (d-svc-pending svc) (list vid #f #f #f)) s]
       [else
        (set-box! (d-svc-last-key svc) #f)
        (set-box! (d-svc-pending svc) (list vid id (cursor-mods s vid) (cursor-binding s vid id)))
        s])]))

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

;; 焦点移开 / 光标导航 → 关文档窗。
(define (docs-cancel-hook s _args)
  (define svc (docs-svc s))
  (if (and svc (unbox (d-svc-win svc))) (close-docs s) s))

;; 文档窗自己的 document 被关（外部）→ 清状态。
(define (docs-doc-closed-hook s args)
  (define svc (docs-svc s))
  (define did (car args))
  ;; 源文档关了 → 清它的本地定义缓存
  (when svc (hash-remove! (unbox (d-svc-local-cache svc)) did))
  (define dw (and svc (unbox (d-svc-win svc))))
  (cond
    [(and dw (eqv? did (d-svc-ddid svc)))
     (set-box! (d-svc-win svc) #f)
     (session-run-hooks s 'docs-state (list #f))]
    [else s]))

(define (docs-handler)
  (lambda (s cmd)
    (cond
      [(cmd-docs-show? cmd) (cmd-show-docs s)]
      [else #f])))

;;; ---------- 注册 ----------

(define (docs-install s)
  (define s0 (install-doc-job! s))
  ;; 常驻文档区：安装时就建好 document / view 并登记 dock 面（默认隐藏）。
  (define-values (s1 ddid dvid)
    (session-add-document s0 "" (session-width s0) 1 #:name "*docs*"))
  (define svc (d-svc ddid dvid (box #f) (box 0) (box #f) (box #f) (box #f)
                     (box #f) (box #f) (box 'idle) (box (make-hash))))
  (define sf (dock-surface 'docs dvid #f #f slot-docs 'height 1 #:border 'window-border))
  (define s2 (session-set-visible (session-add-surface s1 sf) dvid #f))
  (let* ([s3 (session-service-put s2 'docs svc)]
         [s4 (session-add-handler s3 (docs-handler))]
         [s5 (session-add-hook s4 (hook 'complete-selection docs-selection-hook))]
         [s6 (session-add-hook s5 (hook 'docs-scroll docs-scroll-hook))]
         [s7 (session-add-hook s6 (hook 'docs-hscroll docs-hscroll-hook))]
         [s8 (session-add-hook s7 (hook 'docs-focus docs-focus-hook))]
         [s9 (session-add-hook s8 (hook 'focus-changed docs-cancel-hook))]
         [s10 (session-add-hook s9 (hook 'after-nav docs-cancel-hook))]
         [s11 (session-add-hook s10 (hook 'document-closed docs-doc-closed-hook))])
    (session-add-hook s11 (hook 'before-render docs-tick-hook))))

(define docs-spec
  (plugin-spec 'docs docs-install '()))
