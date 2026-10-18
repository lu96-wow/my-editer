#lang racket

;;; plugins/completion/plugin.rkt —— 补全（浮层菜单 + 异步候选池）
;;;
;;; layer  : plugins/completion
;;; effect : set-text-effect / set-face-layer-effect / select-effect（写弹窗）、
;;;          replace-range-effect（接受候选）、submit-service-effect（模块导出）
;;;
;;; 与 edit4 对齐的功能：
;;;   · 候选 = 关键字 + 当前文档顶层定义 + 打开文档里的词；
;;;   · Racket 文档再按 require 解析出「真正导入的绑定名」（pool.rkt）；
;;;   · module->exports 走 worker（completion-exports），结果缓存、在途去重；
;;;   · `(require …)` / `#lang ` 光标处补模块路径（module-paths）；
;;;   · 菜单是 document 浮层；↑↓/Tab/Enter/Esc/打字重筛；
;;;   · 选中候选广播 `complete-selection`，docs 插件可订阅。
;;;
;;; 不抢焦点：浮层 region role = 'panel；临时键表挂在 state.input.modes。
;;;
;;; CONSTRAINT: 与 docs 只通过 complete-selection 配合，不互相 require（CONSTRAINTS §6）。

(provide completion-plugin
         install-completion-popup!
         completion-open?
         completion-popup-view)

(require racket/path
         racket/string
         (except-in racket/list range)
         "../../command/key.rkt"
         "../../base/id.rkt"
         "../../base/keymap.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/input.rkt"
         "../../model/chrome.rkt"
         "../../effects/engine.rkt"
         "../../effects/panel.rkt"
         "../../env/command.rkt"
         "../../env/mode.rkt"
         "../../env/environment.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "../../env/rule.rkt"
         "../../bootstrap/panel.rkt"
         "../../dispatch/context.rkt"
         "../../plugins/highlight/lex.rkt"
         "../lang/source.rkt"
         "../lang/pool.rkt"
         "../lang/context.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/selection.rkt"
         "../../../core/text/base/range.rkt")

;;; ════════════════ store ════════════════

(define session-key 'completion-session)
(define popup-view-key 'completion-popup-view)
(define popup-region-key 'completion-popup-region)
(define cache-key 'completion-cache)
(define jobs-key 'completion-jobs)

(define popup-id 'completion)
(define completion-mode-name 'completion-popup)

(define (completion-session state) (plugin-state state session-key #f))
(define (set-session state s) (plugin-state-set state session-key s))

(define (completion-popup-view state) (plugin-state state popup-view-key #f))
(define (popup-region state) (plugin-state state popup-region-key #f))
(define (popup-float state)
  (and (popup-region state)
       (workspace-float (state-workspace state) popup-id)))

;;; ════════════════ 安装 ════════════════

(define (install-completion-popup! engine state rid)
  (define-values (s1 vid)
    (panel-spec-install! engine state rid
                         (make-panel-spec #:name "*completion*"
                                          #:role 'panel
                                          #:mode 'completion
                                          #:sync #f)))
  (plugin-state-set
   (plugin-state-set s1 popup-view-key vid)
   popup-region-key rid))

(define (completion-open? state) (and (popup-float state) #t))

;;; ════════════════ 光标前的前缀 ════════════════

(define (line-at ev vid)
  (define text (or (engine-view-view-text ev vid) ""))
  (define line (or (engine-view-view-point-line ev vid) 0))
  (define lines (string-split text "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

(define (prefix-at ev vid)
  (define line (line-at ev vid))
  (define col (min (or (engine-view-view-point-column ev vid) 0) (string-length line)))
  (define start (let loop ([i col])
                  (if (and (> i 0) (symbol-char? (string-ref line (sub1 i)))) (loop (sub1 i)) i)))
  (values start (substring line start col)))

;;; ════════════════ 本地候选池 ════════════════

(define (doc-words text)
  (for*/list ([line (in-list (string-split text "\n"))]
              [w (in-list (string-split line #px"[^\\w\\-?!*<>=+./%&:]+"))]
              #:when (and (positive? (string-length w))
                          (char-alphabetic? (string-ref w 0))))
    w))

(define (open-doc-ids state)
  (for/list ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
             #:unless (doc-meta-internal? dm))
    did))

(define (local-words state ev)
  (sort (remove-duplicates
         (append* (for/list ([did (in-list (open-doc-ids state))])
                    (doc-words (or (engine-view-doc-text ev did) "")))))
        string<?))

(define (base-pool state ev vid)
  (define text (or (and vid (engine-view-view-text ev vid)) ""))
  (define-values (_lang forms) (module-context text))
  (define defs (map symbol->string (definitions-of-forms forms)))
  (remove-duplicates
   (append (local-words state ev)
           (hash-keys keyword-set)
           defs)
   equal?))

;;; ════════════════ 打开文档 / 模块上下文 ════════════════

(define (module-path-context? state ev vid)
  (define text (or (and vid (engine-view-view-text ev vid)) ""))
  (and text
       (or (require-context? text
                             (or (engine-view-view-point-line ev vid) 0)
                             (or (engine-view-view-point-column ev vid) 0))
           (lang-context? text
                          (or (engine-view-view-point-line ev vid) 0)
                          (or (engine-view-view-point-column ev vid) 0)))))

;;; ════════════════ 排序 / 过滤 ════════════════

(define (filter-pool pool prefix)
  (define plen (string-length prefix))
  (for/list ([x (in-list pool)]
             #:when (and (> (string-length x) plen)
                         (string=? prefix (substring x 0 plen))))
    x))

(define (rank-candidates cands)
  (sort (remove-duplicates cands equal?)
        (lambda (a b)
          (cond [(< (string-length a) (string-length b)) #t]
                [(> (string-length a) (string-length b)) #f]
                [else (string<? a b)]))))

;;; ════════════════ 缓存 / job ════════════════

(define (cache-of state)
  (plugin-state state cache-key (hash 'exports (hash) 'pending (hash))))
(define (cache-get state key)
  (hash-ref (hash-ref (cache-of state) 'exports) key #f))
(define (cache-put state key value)
  (define c (cache-of state))
  (plugin-state-set state cache-key
                    (hash-set c 'exports (hash-set (hash-ref c 'exports) key value))))
(define (pending? state key)
  (hash-ref (hash-ref (cache-of state) 'pending) key #f))
(define (pending-add state key)
  (define c (cache-of state))
  (plugin-state-set state cache-key
                    (hash-set c 'pending (hash-set (hash-ref c 'pending) key #t))))
(define (pending-del state key)
  (define c (cache-of state))
  (plugin-state-set state cache-key
                    (hash-set c 'pending (hash-remove (hash-ref c 'pending) key))))

(define (jobs-of state) (plugin-state state jobs-key (hash)))
(define (job-add state jid kind tag)
  (plugin-state-set state jobs-key (hash-set (jobs-of state) jid (cons kind tag))))
(define (job-take state jid)
  (define js (jobs-of state))
  (values (hash-ref js jid #f)
          (plugin-state-set state jobs-key (hash-remove js jid))))

(define (submit-job state kind payload tag)
  (define-values (jid s1) (state-next-id state 'job))
  (define s2 (pending-add (job-add s1 jid kind tag) tag))
  (transition s2 (list (submit-service-effect jid kind payload))))

;;; ════════════════ 菜单浮层 ════════════════

(define (popup-window n idx cap)
  (define rows (max 1 (min n (max 1 cap))))
  (values (max 0 (min (- idx (quotient rows 2)) (- n rows))) rows))

(define (session-candidates s) (hash-ref s 'candidates))
(define (session-index s) (hash-ref s 'index))
(define (session-name s)
  (define cs (session-candidates s))
  (and (pair? cs) (list-ref cs (min (session-index s) (sub1 (length cs))))))

(define (session-binding s name)
  (define specs (hash-ref s 'specs #f))
  (define base-dir (hash-ref s 'base-dir #f))
  (and (hash-ref s 'docs? #f) specs base-dir name
       (with-handlers ([exn:fail? (λ (_) #f)])
         (spec-binding-of name specs base-dir (hash-ref s 'open #f)))))

(define (selection-state state s)
  (define vid (hash-ref s 'view))
  (define name (session-name s))
  (state-emit state 'complete-selection
              (list vid name (and name (session-binding s name)))))

(define (popup-content s)
  (define cands (session-candidates s))
  (define n (length cands))
  (define idx (session-index s))
  (define cap (min 8 n))
  (define-values (start rows) (popup-window n idx cap))
  (define shown (take (drop cands start) rows))
  (define inner-w
    (for/fold ([m 1]) ([x (in-list shown)]) (max m (+ 1 (string-length x)))))
  (define text
    (string-join
     (for/list ([x (in-list shown)])
       (define base (string-append " " x))
       (string-append base (make-string (max 0 (- inner-w (string-length base))) #\space)))
     "\n"))
  (values text inner-w (- idx start) start rows))

(define (popup-doc state)
  (define pvid (completion-popup-view state))
  (and pvid (workspace-doc-of-view (state-workspace state) pvid)))

;; 把当前 session 的可见窗口写进弹窗文档；返回 transition。
(define (render-popup state s)
  (define pvid (completion-popup-view state))
  (define pdoc (popup-doc state))
  (define-values (text inner-w local _start _rows) (popup-content s))
  (define doc
    (transition (selection-state state s)
                (append
                 (list (set-text-effect pvid text)
                       (select-effect pvid (selections-one (caret (point local 0)))))
                 (if pdoc
                     (list (set-face-layer-effect
                            pdoc 'completion
                            (append
                             (for/list ([i (in-range (length (string-split text "\n")))])
                               (list i 0 i inner-w 'complete))
                             (list (list local 0 local inner-w 'complete-selected)))))
                     '()))))
  doc)

(define (open-popup state s)
  (define pvid (completion-popup-view state))
  (define rids (popup-region state))
  (unless (and pvid rids)
    (error 'completion "popup 没安装：先调 install-completion-popup!"))
  (define s1 (state-input* (set-session state s)
                           (λ (i) (input-push-mode i completion-mode-name))))
  (define s2 (state-workspace*
              s1
              (λ (ws) (workspace-add-float ws (float popup-id rids pvid (hash-ref s 'view))))))
  (render-popup s2 s))

(define (close-popup state)
  (define s (completion-session state))
  (define vid (and s (hash-ref s 'view #f)))
  (define s1 (state-workspace* state (λ (ws) (workspace-remove-float ws popup-id))))
  (define s2 (state-input* s1 (λ (i)
                                (if (memq completion-mode-name (input-modes i))
                                    (input-pop-mode i)
                                    i))))
  (define s3 (set-session s2 #f))
  (state-emit s3 'complete-selection (list vid #f #f)))

;;; ════════════════ 打开 / 重筛 / 移动 / 接受 ════════════════

(define (msg state text)
  (state-chrome* state (λ (c) (chrome-set-message c text))))

(define (open-with-pool state ev vid prefix pool specs base-dir open docs?)
  (define cands (rank-candidates (filter-pool pool prefix)))
  (cond
    [(null? cands) (transition-pure (msg state (format "completion: no match for ~a" prefix)))]
    [else
     (define-values (start _prefix*) (prefix-at ev vid))
     (define line (or (engine-view-view-point-line ev vid) 0))
     (define s (hash 'view vid 'line line 'start start 'prefix prefix
                     'pool pool 'candidates cands 'index 0
                     'specs specs 'base-dir base-dir 'open open 'docs? docs?))
     (open-popup state s)]))

(define (maybe-open-cached state ev)
  (define vid (focused-vid state))
  (cond
    [(or (not vid) (completion-open? state)) (transition-pure state)]
    [else
     (define-values (_start prefix) (prefix-at ev vid))
     (cond
       [(zero? (string-length prefix)) (transition-pure state)]
       [(module-path-context? state ev vid)
        (define paths (cache-get state 'module-paths))
        (if (list? paths)
            (open-with-pool state ev vid prefix paths #f #f #f #f)
            (transition-pure state))]
       [else
        (define ctx (source-context state ev vid))
        (cond
          [(not ctx)
           (open-with-pool state ev vid prefix (base-pool state ev vid) #f #f #f #f)]
          [else
           (define specs (hash-ref ctx 'specs))
           (define base-dir (hash-ref ctx 'base-dir))
           (define open (hash-ref ctx 'open))
           (define locals (hash-ref ctx 'locals))
           (define key (export-key ctx))
           (define exp (cache-get state key))
           (if (list? exp)
               (open-with-pool state ev vid prefix
                               (append exp locals (base-pool state ev vid))
                               specs base-dir open #t)
               (transition-pure state))])])]))

(define (completion-open ctx)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define vid (ctx-subject ctx))
  (cond
    [(not (view-id? vid)) (transition-pure (msg state "completion: no view"))]
    [(completion-open? state) (transition-pure (close-popup state))]
    [else
     (define-values (_start prefix) (prefix-at ev vid))
     (cond
       [(zero? (string-length prefix))
        (transition-pure (msg state "completion: no word at point"))]
       [(module-path-context? state ev vid)
        (define paths (cache-get state 'module-paths))
        (cond
          [(list? paths) (open-with-pool state ev vid prefix paths #f #f #f #f)]
          [(pending? state 'module-paths)
           (transition-pure (msg state "completion: loading module list…"))]
          [else (submit-job state 'completion-exports '(module-paths) 'module-paths)])]
       [else
        (define ctx* (source-context state ev vid))
        (cond
          [(not ctx*) (open-with-pool state ev vid prefix (base-pool state ev vid) #f #f #f #f)]
          [else
           (define specs (hash-ref ctx* 'specs))
           (define base-dir (hash-ref ctx* 'base-dir))
           (define open (hash-ref ctx* 'open))
           (define locals (hash-ref ctx* 'locals))
           (define key (export-key ctx*))
           (define exp (cache-get state key))
           (cond
             [(list? exp)
              (open-with-pool state ev vid prefix
                              (append exp locals (base-pool state ev vid))
                              specs base-dir open #t)]
             [(pending? state key)
              (transition-pure (msg state "completion: loading require exports…"))]
             [else
              (submit-job state 'completion-exports
                          (list 'exports (path->string base-dir) specs open)
                          key)])])])]))

(define (completion-move ctx delta)
  (define state (ctx-state ctx))
  (define s (completion-session state))
  (cond
    [(not s) (transition-pure state)]
    [else
     (define n (length (session-candidates s)))
     (define s1 (hash-set s 'index (modulo (+ (session-index s) delta) n)))
     (render-popup (set-session state s1) s1)]))

(define (completion-refine-hook state ev args)
  (define s (completion-session state))
  (cond
    [(not s) (transition-pure state)]
    [else
     (define vid (hash-ref s 'view))
     (cond
       [(not (engine-view-exists? (engine-view-engine ev) vid))
        (transition-pure (close-popup state))]
       [else
        (define-values (start prefix) (prefix-at ev vid))
        (cond
          [(zero? (string-length prefix)) (transition-pure (close-popup state))]
          [else
           (define cands (rank-candidates (filter-pool (hash-ref s 'pool) prefix)))
           (cond
             [(null? cands) (transition-pure (close-popup state))]
             [else
              (define idx (min (session-index s) (sub1 (length cands))))
              (define s1 (hash-set (hash-set (hash-set s 'candidates cands) 'index idx)
                                   'prefix prefix))
              (define s2 (hash-set (hash-set s1 'start start) 'line
                                   (or (engine-view-view-point-line ev vid) 0)))
              (render-popup (set-session state s2) s2)])])])]))

(define (completion-accept ctx)
  (define state (ctx-state ctx))
  (define s (completion-session state))
  (cond
    [(not s) (transition-pure state)]
    [else
     (define cand (session-name s))
     (define vid (hash-ref s 'view))
     (define line (hash-ref s 'line))
     (define start (hash-ref s 'start))
     (define prefix (hash-ref s 'prefix))
     (define s1 (close-popup (state-input* state input-clear-pending)))
     (cond
       [(not cand) (transition-pure s1)]
       [else
        (transition
         (state-chrome* s1 (lambda (c) (chrome-set-message c (format "complete: ~a" cand))))
         (list (replace-range-effect vid
                                     (range-of (point line start)
                                               (point line (+ start (string-length prefix))))
                                     cand)
               (select-effect vid
                              (selections-one
                               (caret (point line (+ start (string-length cand))))))))])]))
(define (completion-cancel ctx)
  (transition-pure (close-popup (ctx-state ctx))))

(define (completion-noop ctx) (transition-pure (ctx-state ctx)))

;;; ════════════════ job-done ════════════════

(define (completion-on-job state ev args)
  (define jid (car args))
  (define result (cadr args))
  (define-values (job s1) (job-take state jid))
  (cond
    [(not job) (transition-pure state)]
    [else
     (define kind (car job))
     (define tag (cdr job))
     (define s2 (pending-del s1 tag))
     (cond
       [(and (eq? kind 'completion-exports)
             (list? result)
             (andmap string? result))
        (maybe-open-cached (cache-put s2 tag result) ev)]
       [else (transition-pure s2)])]))

;;; ════════════════ 键位 ════════════════

(define completion-keys
  (keys [(key 'c 'ctrl) (key '/) 'complete-open]
        [(key '/ 'alt) 'complete-open]))

(define completion-popup-keys
  (keys [(key 'up)     'complete-prev]
        [(key 'down)   'complete-next]
        [(key 'enter)  'complete-accept]
        [(key 'tab)    'complete-accept]
        [(key 'escape) 'complete-cancel]
        [(key 'left)   'complete-noop]
        [(key 'right)  'complete-noop]
        [(key 'g 'ctrl) 'complete-cancel]))

(define completion-doc-keys
  (keys [(key 'up)   'complete-prev]
        [(key 'down) 'complete-next]))

;;; ════════════════ 插件 ════════════════

(define (completion-plugin)
  (make-plugin
   'completion
   #:env (make-environment
          #:modes (hash 'completion (make-mode #:keymaps (list completion-doc-keys)
                                               #:fallback 'ignore))
          #:keymaps (hash completion-mode-name completion-popup-keys)
          #:commands (hash 'complete-open (cmd completion-open)
                           'complete-next (cmd (λ (ctx) (completion-move ctx 1)))
                           'complete-prev (cmd (λ (ctx) (completion-move ctx -1)))
                           'complete-accept (cmd completion-accept)
                           'complete-cancel (cmd completion-cancel)
                           'complete-noop (cmd completion-noop))
          #:rules (list (make-rule 'always completion-keys)))
   #:hooks (list (make-hook 'after-edit completion-refine-hook)
                 (make-hook 'focus-changed
                            (λ (s ev _args)
                              (define cur (completion-session s))
                              (define vid (focused-vid s))
                              (transition-pure
                               (if (and cur (not (equal? vid (hash-ref cur 'view))))
                                   (close-popup s)
                                   s))))
                 (make-hook 'job-done completion-on-job))))
