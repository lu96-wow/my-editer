#lang racket

;;; plugins/docs/plugin.rkt —— 标识符文档面板
;;;
;;; layer  : plugins/docs
;;; effect : set-text-effect（写面板 buffer）
;;;
;;; 结构（全部是数据）：
;;;
;;;   面板   *docs*（role 'tool，mode 'docs）—— 和文件树 / 资源列表一样是 buffer 支撑的面板；
;;;   命令   C-c h  -> 取光标处的标识符，查文档，显示面板；再按一次收起；
;;;   钩子   after-nav -> 面板开着就跟着光标刷新（**不会自动收起**）。
;;;
;;; 面板一旦弹出就一直留在（下方的固定高度面板区），只有 C-c h 才收起 ——
;;; “看着文档改代码”不会被焦点移动打断。
;;;
;;; 文档来源（暂定，先做本地，不接网络）：
;;;   1. 内置关键字表；
;;;   2. 当前文档里的顶层定义（扫 `(define …` 行）。
;;; 以后接 stdlib/网络文档 = 换掉 `docs-text-for` 的实现 + 用 spawn-effect，
;;; 面板 / 命令 / 钩子的形状不变。

(provide docs-plugin
         install-docs-panel!     ; 宿主装配时调用（建 *docs* 文档 + region）
         docs-panel-view         ; 面板 view-id（测试 / 诊断用）
         docs-open?)             ; 面板当前是否显示

(require racket/list
         racket/string
         "../../../edit-tui/command/key.rkt"
         "../../base/keymap.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../base/id.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../model/chrome.rkt"
         "../../effects/engine.rkt"
         "../../env/command.rkt"
         "../../env/environment.rkt"
         "../../env/mode.rkt"
         "../../env/rule.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "../../bootstrap/panel.rkt"
         "../../dispatch/context.rkt")

(define store-key 'docs)

;;; ════════════════ 面板 ════════════════

(define (docs-panel-view state)
  (plugin-state state store-key #f))

(define (docs-panel-spec)
  (make-panel-spec
                   #:name "*docs*"
                   #:role 'tool
                   #:mode 'docs
                   #:sync #f))       ; 文本由命令 / 钩子写，不需要每帧同步

(define (install-docs-panel! engine state rid)
  (define-values (s1 vid) (panel-spec-install! engine state rid (docs-panel-spec)))
  (plugin-state-set s1 store-key vid))

(define docs-keys
  (keys [(key 'left)  'nav-left]
        [(key 'right) 'nav-right]
        [(key 'up)    'nav-up]
        [(key 'down)  'nav-down]
        [(key 'home)  'nav-home]
        [(key 'end)   'nav-end]))

;;; ════════════════ 光标处的标识符 ════════════════

(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (memv c '(#\- #\_ #\? #\! #\* #\> #\< #\= #\+ #\. #\/ #\% #\&))))

(define (line-at ev vid)
  (define text (or (engine-view-view-text ev vid) ""))
  (define line (or (engine-view-view-point-line ev vid) 0))
  (define lines (string-split text "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

;; 光标处的标识符（光标在词尾也认；实在没有 → #f）
(define (identifier-at ev vid)
  (define line (line-at ev vid))
  (define n (string-length line))
  (define col (min (or (engine-view-view-point-column ev vid) 0) n))
  (define start (let loop ([i col])
                  (if (and (> i 0) (ident-char? (string-ref line (sub1 i)))) (loop (sub1 i)) i)))
  (define end (let loop ([i col])
                (if (and (< i n) (ident-char? (string-ref line i))) (loop (add1 i)) i)))
  (and (< start end) (substring line start end)))

;;; ════════════════ 文档来源 ════════════════

(define builtin-docs
  (hash "define"  "(define name value)\n(define (name arg ...) body ...)\n绑定一个值或函数。"
        "lambda"  "(lambda (arg ...) body ...)\n匿名函数。"
        "let"     "(let ([name value] ...) body ...)\n局部绑定；let* 顺序绑定，letrec 递归绑定。"
        "let*"    "(let* ([name value] ...) body ...)\n逐条可见的局部绑定。"
        "letrec"  "(letrec ([name value] ...) body ...)\n互相引用的局部绑定。"
        "if"      "(if test then else)\n条件表达式。"
        "cond"    "(cond [test body ...] ... [else body ...])\n多分支条件。"
        "when"    "(when test body ...)\n为真时依次求值。"
        "unless"  "(unless test body ...)\n为假时依次求值。"
        "match"   "(match value [pattern body ...] ...)\n模式匹配。"
        "for"     "(for ([id seq] ...) body ...)\n遍历。"
        "for/list" "(for/list ([id seq] ...) body ...)\n遍历并收集到列表。"
        "map"     "(map proc lst ...)\n对每个元素应用 proc。"
        "filter"  "(filter pred lst)\n保留 pred 为真的元素。"
        "foldl"   "(foldl proc init lst ...)\n从左到右折叠。"
        "cons"    "(cons a d)\n构造 pair。"
        "car"     "(car p)\npair 的第一个元素。"
        "cdr"     "(cdr p)\npair 的第二个元素。"
        "list"    "(list v ...)\n构造列表。"
        "hash"    "(hash k v ...)\n构造不可变哈希。"
        "struct"  "(struct name (field ...))\n定义结构体类型。"
        "require" "(require module ...)\n导入模块。"
        "provide" "(provide name ...)\n导出名称。"
        "set!"    "(set! id value)\n修改绑定。"
        "begin"   "(begin body ...)\n顺序求值，返回最后一个值。"))

;; 文档里提到 ident 的顶层 define 行
(define (local-def-for text ident)
  (define rx (regexp (format "[( ]~a[ )]" (regexp-quote ident))))
  (for/first ([line (in-list (string-split text "\n"))]
              #:when (and (regexp-match? #px"^\\s*\\(define" line)
                          (regexp-match? rx line)))
    (string-trim line)))

;; 某个 view 上的标识符的文档文本（#f = 没有）
(define (docs-text-for state ev vid ident)
  (cond
    [(not (and (view-id? vid) ident)) #f]
    [else
     (define did (workspace-doc-of-view (state-workspace state) vid))
     (define text (and did (engine-view-doc-text ev did)))
     (define inline (and text (local-def-for text ident)))
     (define builtin (hash-ref builtin-docs ident #f))
     (cond
       [(and inline builtin) (format "~a\n\n— 本文件定义 —\n~a" builtin inline)]
       [inline inline]
       [builtin builtin]
       [else #f])]))

;;; ════════════════ 显示 / 收起 ════════════════

(define (docs-region state)
  (define vid (docs-panel-view state))
  (and vid (workspace-view-region (state-workspace state) vid)))

(define (docs-open? state)
  (define reg (docs-region state))
  (and reg (tree-visible? (workspace-layout (state-workspace state)) (region-key reg)) #t))

(define (hide-docs state)
  (define reg (docs-region state))
  (if (not reg)
      state
      (state-workspace*
       state
       (λ (ws) (struct-copy workspace ws
                            [layout (tree-hide (workspace-layout ws) (region-key reg))])))))

;; 显示面板（并在状态栏报告标识符）
(define (show-docs state ident)
  (define reg (docs-region state))
  (cond
    [(not reg) (state-chrome* state (λ (c) (chrome-set-message c "docs: panel not installed")))]
    [else
     (state-workspace*
      (state-chrome* state (λ (c) (chrome-set-message c (format "docs: ~a" ident))))
      (λ (ws) (struct-copy workspace ws
                           [layout (tree-show (workspace-layout ws) (region-key reg))])))]))

;;; ════════════════ 命令：M-h ════════════════

(define (docs-toggle-command)
  (cmd
   (λ (ctx)
     (define state (ctx-state ctx))
     (define ev (ctx-engine ctx))
     (define vid (ctx-subject ctx))
     (define pvid (docs-panel-view state))
     (cond
       [(not pvid)
        (transition-pure (state-chrome* state (λ (c) (chrome-set-message c "docs: panel not installed"))))]
       ;; 面板开着 -> 再按一次就收起（不管焦点在哪：这就是“手动关闭”）
       [(docs-open? state) (transition-pure (hide-docs state))]
       [else
        (define ident (and (view-id? vid) (identifier-at ev vid)))
        (define text (docs-text-for state ev vid ident))
        (cond
          [(not text)
           (transition-pure
            (state-chrome* state
                           (λ (c) (chrome-set-message c (format "docs: no docs for ~a" (or ident "-"))))))]
          [else
           ;; 打开底部面板会改变布局：先写面板文本，再把焦点 view 夹回窗口
           ;; （core 的 view-ensure!，由 ensure-view-effect 触发）。
           (transition (show-docs state ident)
                       (append (list (set-text-effect pvid text))
                               (if (and (view-id? vid) (not (equal? vid pvid)))
                                   (list (ensure-view-effect vid))
                                   '())))])]))))

;;; ════════════════ 键位：C-c h ════════════════

(define docs-keys-table
  (keys [(key 'c 'ctrl) (key 'h) 'docs-toggle]))

;;; ════════════════ 钩子 ════════════════

;; 光标移动：面板开着就刷新。
;; 光标落在分隔符 / 没有文档的标识符上时**保持现状**（不来回闪），
;; 收起只由 M-h 或“焦点离开编辑器”触发。
(define (docs-on-nav state ev args)
  (define vid (state-focus state))
  (define pvid (docs-panel-view state))
  (cond
    [(not (docs-open? state)) (transition-pure state)]
    [(or (not (view-id? vid)) (equal? vid pvid)) (transition-pure state)]
    [else
     (define ident (identifier-at ev vid))
     (define text (docs-text-for state ev vid ident))
     ;; 只刷新内容，不再发 ensure-view：面板本来就开着，布局没变。
     (if text
         (transition (show-docs state ident)
                     (list (set-text-effect pvid text)))
         (transition-pure state))]))

(define (docs-plugin)
  (make-plugin
   'docs
   #:env (make-environment
          #:modes (hash 'docs (make-mode #:keymaps (list docs-keys) #:fallback 'ignore))
          #:commands (hash 'docs-toggle (docs-toggle-command))
          #:rules (list (make-rule 'always docs-keys-table)))
   #:hooks (list (make-hook 'after-nav docs-on-nav))))
