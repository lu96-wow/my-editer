#lang racket

;;; plugins/completion/plugin.rkt —— 补全（文档浮层 + 临时键表）
;;;
;;; layer  : plugins/completion
;;; effect : set-text-effect / set-faces-effect（写弹窗文档）、select-effect（弹窗光标）、
;;;          replace-range-effect（把候选写回编辑器）
;;;
;;; 流程：
;;;
;;;   C-c /       取光标前的词做前缀 -> 收集候选 -> 打开文档浮层（不插入文本）
;;;   Up / Down   在弹窗里上下移动选择（= 移动弹窗文档的光标行）
;;;   Enter / Tab 接受：把前缀换成选中的候选
;;;   Esc / C-g   取消：关浮层，文本不变
;;;   继续打字     自动关浮层（after-edit 钩子），照常输入
;;;
;;; 两个关键设计：
;;;
;;;   1. **浮层就是 document**：`*completion*` 是一块真实的 region + view，
;;;      只是不在 layout 树里，绘制时作为 deep 更高的 panel 交给 core 合成。
;;;      「所有显示都用 document」于是成立：
;;;        候选列表 = 文档文本（set-text-effect）
;;;        选中行   = 该文档的光标行（select-effect）+ 一条 face（set-faces-effect）
;;;      擦除 / 移动 / 遮挡全部由 core 的增量 diff 负责 —— 框架不需要记任何矩形。
;;;
;;;   2. **临时键表**：打开浮层时把 'completion-popup 这张 keymap 挂到
;;;      `state.input.modes`（规则层序最高的一层），关掉时摘掉。
;;;      于是 Up/Down 只在浮层开着时改变含义，关掉立刻还给编辑器。

(provide completion-plugin
         install-completion-popup!
         completion-open
         completion-accept
         completion-cancel
         completion-move
         completion-candidates
         completion-session
         completion-popup-view
         completion-open?
         prefix-at
         local-words
         completion-mode-name)

(require racket/string
         "../../../edit-tui/command/key.rkt"
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
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/selection.rkt"
         "../../../core/text/base/range.rkt")

;;; ════════════════ store ════════════════

(define session-key 'completion-session)
(define popup-view-key 'completion-popup-view)
(define popup-region-key 'completion-popup-region)

(define popup-id 'completion)
;; 临时键表的**名字**（env.keymaps 里的键；input.modes 存的就是这种名字）
(define completion-mode-name 'completion-popup)

(define (completion-session state) (plugin-state state session-key #f))
(define (set-session state s) (plugin-state-set state session-key s))

(define (completion-popup-view state) (plugin-state state popup-view-key #f))
(define (popup-region state) (plugin-state state popup-region-key #f))

(define (popup-float state)
  (and (popup-region state)
       (workspace-float (state-workspace state) popup-id)))

;;; ════════════════ 安装：建 *completion* 文档 + region（不进 layout） ════════════════

(define (install-completion-popup! engine state rid)
  (define-values (s1 vid)
    (panel-spec-install! engine state rid
                         (make-panel-spec 'completion
                                          #:name "*completion*"
                                          #:role 'panel       ; 不可聚焦：焦点始终留在编辑器
                                          #:mode 'completion
                                          #:sync #f)))
  (plugin-state-set
   (plugin-state-set s1 popup-view-key vid)
   popup-region-key rid))

;; 浮层开着？
(define (completion-open? state) (and (popup-float state) #t))

;;; ════════════════ 词法：光标前的词 ════════════════

(define (word-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (memv c '(#\- #\_ #\? #\! #\* #\> #\< #\= #\+ #\. #\/ #\% #\&))))

(define (line-at ev vid)
  (define text (or (engine-view-view-text ev vid) ""))
  (define line (or (engine-view-view-point-line ev vid) 0))
  (define lines (string-split text "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

;; → (values start prefix)
(define (prefix-at ev vid)
  (define line (line-at ev vid))
  (define col (min (or (engine-view-view-point-column ev vid) 0) (string-length line)))
  (define start (let loop ([i col])
                  (if (and (> i 0) (word-char? (string-ref line (sub1 i)))) (loop (sub1 i)) i)))
  (values start (substring line start col)))

;;; ════════════════ 候选 ════════════════

(define (doc-words text)
  (for*/list ([line (in-list (string-split text "\n"))]
              [w (in-list (string-split line #px"[^\\w\\-?!*<>=+./%&]+"))]
              #:when (and (positive? (string-length w))
                          (char-alphabetic? (string-ref w 0))))
    w))

(define (open-doc-ids state)
  (for/list ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
             #:unless (doc-meta-internal? dm))
    did))

;; 所有打开文档（非 internal）里出现过的词，去重 + 排序
(define (local-words state ev)
  (sort (remove-duplicates
         (append* (for/list ([did (in-list (open-doc-ids state))])
                    (doc-words (or (engine-view-doc-text ev did) "")))))
        string<?))

;; 与 prefix 匹配、且比 prefix 长的候选（大小写不敏感）
(define (completion-candidates state ev prefix)
  (define p (string-downcase prefix))
  (for/list ([w (in-list (local-words state ev))]
             #:when (and (> (string-length w) (string-length prefix))
                         (string-prefix? (string-downcase w) p)))
    w))

;;; ════════════════ 弹窗文档 ↔ 选中行 ════════════════

;; 弹窗文档的每一行（候选）
(define (popup-lines ev pvid)
  (string-split (or (engine-view-view-text ev pvid) "") "\n"))

;; 选中行 = 弹窗文档的光标行
(define (selected-index ev pvid)
  (or (engine-view-view-point-line ev pvid) 0))

;; 选中行的文本（从**文档**读，不另存一份）
(define (selected-text ev pvid)
  (define ls (popup-lines ev pvid))
  (define i (selected-index ev pvid))
  (and (< i (length ls)) (list-ref ls i)))

;; 选中行的 face（整行高亮）—— 写回弹窗文档
(define (selection-faces ev pvid)
  (define ls (popup-lines ev pvid))
  (define i (selected-index ev pvid))
  (if (< i (length ls))
      (list (list i 0 i (string-length (list-ref ls i)) 'selection))
      '()))

(define (popup-doc state)
  (define pvid (completion-popup-view state))
  (and pvid (workspace-doc-of-view (state-workspace state) pvid)))

;;; ════════════════ 打开 / 关闭 ════════════════

;; 打开：写候选到弹窗文档 -> 光标到第一行 -> 高亮选中行 -> 加浮层 -> 挂临时键表
(define (open-popup state ev vid s)
  (define pvid (completion-popup-view state))
  (define rids (popup-region state))
  (define cands (hash-ref s 'cands))
  (unless (and pvid rids)
    (error 'completion "popup 没安装：先调 install-completion-popup!"))
  (define s1 (set-session state s))
  (define s2 (state-workspace*
              s1
              (λ (ws) (workspace-add-float ws (float popup-id rids pvid vid)))))
  (define doc (popup-doc state))
  (transition s2
              (append
               (list (set-text-effect pvid (string-join cands "\n"))
                     (select-effect pvid (selections-one (caret (point 0 0)))))
               (if doc
                   (list (set-faces-effect doc
                                           (list (list 0 0 0 (string-length (car cands)) 'selection))))
                   '()))))

;; 关闭：去浮层 + 摘临时键表 + 清会话
(define (close-popup state)
  (define s1 (state-workspace* state (λ (ws) (workspace-remove-float ws popup-id))))
  (define s2 (state-input* s1 (λ (i)
                                (if (memq completion-mode-name (input-modes i))
                                    (input-pop-mode i)
                                    i))))
  (set-session s2 #f))

;;; ════════════════ 命令 ════════════════

(define (msg state text)
  (state-chrome* state (λ (c) (chrome-set-message c text))))

;; C-c / ：开 / 关浮层
(define (completion-open ctx)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define vid (ctx-subject ctx))
  (cond
    [(not (view-id? vid))
     (transition-pure (msg state "completion: no view"))]
    [(completion-open? state)
     (transition-pure (close-popup state))]
    [else
     (define-values (start prefix) (prefix-at ev vid))
     (cond
       [(zero? (string-length prefix))
        (transition-pure (msg state "completion: no word at point"))]
       [else
        (define cands (completion-candidates state ev prefix))
        (cond
          [(null? cands) (transition-pure (msg state (format "completion: no match for ~a" prefix)))]
          [else
           (define s (hash 'view vid
                           'line (or (engine-view-view-point-line ev vid) 0)
                           'start start
                           'end (+ start (string-length prefix))
                           'cands cands))
           (define s1 (state-input* state (λ (i) (input-push-mode i completion-mode-name))))
           (open-popup s1 ev vid s)])])]))

;; Up / Down：移动弹窗文档的光标行（选中行）
(define (completion-move ctx delta)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define pvid (completion-popup-view state))
  (cond
    [(not (completion-open? state)) (transition-pure state)]
    [else
     (define ls (popup-lines ev pvid))
     (define n (length ls))
     (define i (modulo (+ (selected-index ev pvid) delta) n))
     (define text (list-ref ls i))
     (define doc (popup-doc state))
     (transition (msg state (format "complete: ~a (~a/~a)" text (add1 i) n))
                 (append
                  (list (select-effect pvid (selections-one (caret (point i 0)))))
                  (if doc
                      (list (set-faces-effect doc (list (list i 0 i (string-length text) 'selection))))
                      '())))]))

;; Enter / Tab：接受（把编辑器里 [start,end) 换成弹窗里选中的那一行）
(define (completion-accept ctx)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define s (completion-session state))
  (define pvid (completion-popup-view state))
  (cond
    [(or (not s) (not (completion-open? state))) (transition-pure (close-popup state))]
    [else
     (define text (selected-text ev pvid))
     (define vid (hash-ref s 'view))
     (define line (hash-ref s 'line))
     (define start (hash-ref s 'start))
     (define end (hash-ref s 'end))
     (define s1 (close-popup (state-input* state input-clear-pending)))
     (transition (msg s1 (format "complete: ~a" text))
                 (list (replace-range-effect vid (range-of (point line start) (point line end)) text)
                       (select-effect vid (selections-one (caret (point line (+ start (string-length text))))))))]))

;; Esc / C-g：取消
(define (completion-cancel ctx)
  (transition-pure (close-popup (ctx-state ctx))))

(define (cmd-with f) (cmd f))

(define completion-keys
  (keys [(key 'c 'ctrl) (key '/) 'complete-open]))

;; 临时键表：只在浮层开着时生效（input.modes 是最高规则层）
(define completion-popup-keys
  (keys [(key 'up)     'complete-prev]
        [(key 'down)   'complete-next]
        [(key 'enter)  'complete-accept]
        [(key 'tab)    'complete-accept]
        [(key 'escape) 'complete-cancel]
        [(key 'g 'ctrl) 'complete-cancel]))

;; 弹窗文档自己的 mode（它通常不被聚焦，留着是为了只读 + 方向键规则完备）
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
          #:commands (hash 'complete-open (cmd-with completion-open)
                           'complete-next (cmd-with (λ (ctx) (completion-move ctx 1)))
                           'complete-prev (cmd-with (λ (ctx) (completion-move ctx -1)))
                           'complete-accept (cmd-with completion-accept)
                           'complete-cancel (cmd-with completion-cancel))
          #:rules (list (make-rule 'always completion-keys)))
   ;; 浮层开着时又**在编辑器里**打字 / 焦点变了 -> 关掉浮层（文本照常进编辑器）。
   ;; 写浮层自己的文档（set-text-effect）不算编辑，这里再按 doc 过滤一次更稳。
   #:hooks (list (make-hook 'after-edit
                            (λ (s ev args)
                              (define pdoc (popup-doc s))
                              (transition-pure
                               (if (and (completion-open? s)
                                        (not (and pdoc (pair? args) (equal? (car args) pdoc))))
                                   (close-popup s)
                                   s))))
                 (make-hook 'focus-changed
                            (λ (s ev args)
                              (transition-pure (if (completion-open? s) (close-popup s) s)))))))
