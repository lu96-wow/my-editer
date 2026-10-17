#lang racket

;;; plugins/completion/plugin.rkt —— 补全（浮层菜单 + 临时键表）
;;;
;;; layer  : plugins/completion
;;; effect : replace-range-effect（接受候选时替换光标前的词）+ select-effect（光标放到词尾）
;;;
;;; 流程：
;;;
;;;   C-c /       取光标前的词做前缀 -> 收集候选 -> 打开浮层弹窗（不插入文本）
;;;   Up / Down   在弹窗里上下移动选择
;;;   Enter / Tab 接受：把前缀换成选中的候选
;;;   Esc / C-g   取消：关弹窗，文本不变
;;;   继续打字     自动关弹窗（after-edit 钩子），照常输入
;;;
;;; 两个框架能力在这里第一次被用上：
;;;   · **浮层**（model/overlay.rkt + projection/popup.rkt）：弹窗锚在光标处，
;;;     不抢焦点，每帧跟着光标走；
;;;   · **临时键表**（input.modes）：打开弹窗时把 'completion-popup 这张 keymap
;;;     挂到 state.input.modes 上，关掉时摘掉。它是规则层序最高的一层
;;;     （dispatch/rules.rkt 的 input-mode-rules 按名字查 env.keymaps），
;;;     所以 Up/Down 只在弹窗开着时改变含义，弹窗一关就还给编辑器。
;;;
;;; 会话（store['completion]）：view / line / start / end / last / cands。
;;; 会话是否还有效**看缓冲内容**（光标仍在 [start,end) 末尾，且 [start,end) 就是上次的候选），
;;; 不看版本 token —— 这样“用户中途改了文本”自然失效。

(provide completion-plugin
         completion-open
         completion-accept
         completion-cancel
         completion-move
         completion-candidates
         completion-session
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
         "../../model/chrome.rkt"
         "../../model/overlay.rkt"
         "../../model/input.rkt"
         "../../effects/engine.rkt"
         "../../env/command.rkt"
         "../../env/mode.rkt"
         "../../env/environment.rkt"
         "../../env/rule.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "../../dispatch/context.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/selection.rkt"
         "../../../core/text/base/range.rkt")

(define store-key 'completion)

(define (completion-session state) (plugin-state state store-key #f))
(define (set-session state s) (plugin-state-set state store-key s))

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

;;; ════════════════ 会话 ════════════════

;; 会话还有效？看缓冲内容和光标位置，不看版本 token。
(define (session-valid? ev s)
  (cond
    [(not (hash? s)) #f]
    [else
     (define vid (hash-ref s 'view))
     (define line (line-at ev vid))
     (define start (hash-ref s 'start))
     (define end (hash-ref s 'end))
     (and (= (or (engine-view-view-point-line ev vid) -1) (hash-ref s 'line))
          (<= end (string-length line))
          (>= start 0)
          (equal? (substring line start end) (hash-ref s 'last))
          (equal? (engine-view-view-point-column ev vid) end))]))

(define (fresh-session state ev vid)
  (define-values (start prefix) (prefix-at ev vid))
  (cond
    [(zero? (string-length prefix)) (cons #f "completion: no word at point")]
    [else
     (define cands (completion-candidates state ev prefix))
     (cond
       [(null? cands) (cons #f (format "completion: no match for ~a" prefix))]
       [else
        (hash 'view vid
              'line (or (engine-view-view-point-line ev vid) 0)
              'start start
              'end (+ start (string-length prefix))
              'last prefix
              'cands cands
              'index -1)])]))

;; 用 text 替换会话当前区间 [start, end)，并把光标放到新词尾。
;;
;; 注意：替换区间是**会话里记录的 end**（当前缓冲里的词长），
;; 不是 start + (string-length text) —— 候选通常比原词长。
(define (replace-and-place state s vid text idx)
  (define line (hash-ref s 'line))
  (define start (hash-ref s 'start))
  (define end-old (hash-ref s 'end))
  (define end-new (+ start (string-length text)))
  (define s* (hash-set (hash-set (hash-set s 'end end-new) 'last text) 'index idx))
  (values (set-session state s*)
          (list (replace-range-effect vid
                                      (range-of (point line start) (point line end-old))
                                      text)
                (select-effect vid (selections-one (caret (point line end-new)))))))

;;; ════════════════ 弹窗 / 临时模态 ════════════════

(define popup-id 'completion)
;; 临时键表的**名字**（env.keymaps 里的键；input.modes 存的就是这种名字）
(define completion-mode-name 'completion-popup)

(define (popup-open? state) (and (state-popup-get state popup-id) #t))

;; 打开弹窗 = 写会话 + 显示浮层 + push 临时模态（Up/Down/Enter/Esc 归弹窗）
(define (open-popup state ev vid s)
  (define cands (hash-ref s 'cands))
  (define s1 (set-session state s))
  (define s2 (state-popup-show s1 popup-id vid cands 0))
  (define s3 (state-input* s2 (λ (i) (input-push-mode i completion-mode-name))))
  (state-chrome* s3 (λ (c) (chrome-set-message c (format "complete: ~a (~a/~a)"
                                                        (car cands) 1 (length cands))))))

;; 关闭弹窗 = 去掉浮层 + pop 临时模态（会话留着，方便重复 C-c / 再开）
(define (close-popup state)
  (define s1 (state-popup-hide state popup-id))
  (state-input* s1 (λ (i)
                     (if (memq completion-mode-name (input-modes i))
                         (input-pop-mode i)
                         i))))

;;; ════════════════ 命令 ════════════════

;; C-c / ：取前缀 -> 算候选 -> 开弹窗（**不改文本**）
(define (completion-open ctx)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define vid (ctx-subject ctx))
  (cond
    [(not (view-id? vid))
     (transition-pure (state-chrome* state (λ (c) (chrome-set-message c "completion: no view"))))]
    [(popup-open? state)                    ; 已经开着：再按一次 = 关掉
     (transition-pure (close-popup state))]
    [else
     (define old (completion-session state))
     (define s (if (and (session-valid? ev old) (equal? (hash-ref old 'view) vid))
                   old
                   (fresh-session state ev vid)))
     (cond
       [(not (hash? s))
        (transition-pure (state-chrome* state (λ (c) (chrome-set-message c (cdr s)))))]
       [else (transition-pure (open-popup state ev vid s))])]))

;; Up / Down：在弹窗里移动选择
(define (completion-move ctx delta)
  (define state (ctx-state ctx))
  (define p (state-popup-get state popup-id))
  (cond
    [(not p) (transition-pure state)]
    [else
     (define s1 (state-popup-move state popup-id delta))
     (define p1 (state-popup-get s1 popup-id))
     (define sel (popup-selected p1))
     (transition-pure
      (state-chrome* s1 (λ (c) (chrome-set-message c (format "complete: ~a (~a/~a)"
                                                            (popup-line p1 sel)
                                                            (add1 sel)
                                                            (length (popup-lines p1)))))))]))

;; Enter / Tab：接受当前选择（替换前缀）
(define (completion-accept ctx)
  (define state (ctx-state ctx))
  (define ev (ctx-engine ctx))
  (define p (state-popup-get state popup-id))
  (define sess (completion-session state))
  (cond
    [(or (not p) (not sess)) (transition-pure (close-popup state))]
    [else
     (define vid (hash-ref sess 'view))
     (define line (hash-ref sess 'line))
     (define start (hash-ref sess 'start))
     (define end (hash-ref sess 'end))
     (define text (popup-line p (or (popup-selected p) 0)))
     (define s0 (state-input* state input-clear-pending))
     (transition
      (state-chrome* (close-popup s0)
                     (λ (c) (chrome-set-message c (format "complete: ~a" text))))
      (list (replace-range-effect vid (range-of (point line start) (point line end)) text)
            (select-effect vid (selections-one (caret (point line (+ start (string-length text))))))))]))

;; Esc / C-g：取消
(define (completion-cancel ctx)
  (transition-pure (close-popup (ctx-state ctx))))

(define (cmd-with f) (cmd f))

(define completion-keys
  ;; 打开弹窗用的是 C-c /（普通规则层，不需要模态）
  (keys [(key 'c 'ctrl) (key '/) 'complete-open]))

(define completion-popup-keys
  ;; 临时模态的键表：只在弹窗开着时生效（input.modes 是最高的规则层）
  (keys [(key 'up)    'complete-prev]
        [(key 'down)  'complete-next]
        [(key 'enter) 'complete-accept]
        [(key 'tab)   'complete-accept]
        [(key 'escape) 'complete-cancel]
        [(key 'g 'ctrl) 'complete-cancel]))

;;; ════════════════ 插件 ════════════════

(define (completion-plugin)
  (make-plugin
   'completion
   #:env (make-environment
          #:keymaps (hash completion-mode-name completion-popup-keys)
          #:commands (hash 'complete-open (cmd-with completion-open)
                           'complete-next (cmd-with (λ (ctx) (completion-move ctx 1)))
                           'complete-prev (cmd-with (λ (ctx) (completion-move ctx -1)))
                           'complete-accept (cmd-with completion-accept)
                           'complete-cancel (cmd-with completion-cancel))
          #:rules (list (make-rule 'always completion-keys)))
   ;; 弹窗开着时又打字 / 焦点变了 -> 关掉弹窗（文本照常进 buffer）
   #:hooks (list (make-hook 'after-edit
                            (λ (s ev args)
                              (transition-pure (if (popup-open? s) (close-popup s) s))))
                 (make-hook 'focus-changed
                            (λ (s ev args)
                              (transition-pure (if (popup-open? s) (close-popup s) s)))))))
