#lang racket

;;; edit-tui/test/plugins.rkt —— 高亮 / 补全 / 文档 三个插件
;;;
;;; 只走公开接口：plugin 数据 + dispatch/process-events + 少量 core 查询。
;;;
;;;   1. 高亮：startup! 之后 document-face-at 能读到 keyword / string / comment / number 的 face；
;;;      编辑后（after-edit 信号）重新上色，且不把文档标脏；**非 .rkt 文件不上色**；
;;;   2. 补全：C-c / 打开**文档浮层**（不改文本）；↑↓ 选；Enter 接受；Esc 取消；
;;;   3. 文档：C-c h 打开面板并写入标识符文档；after-nav 跟随光标刷新；
;;;      面板**不会自动收起**，只有 C-c h 再按一次才关。

(require rackunit
         racket/async-channel
         racket/string
         "../command/key.rkt"
         "../command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/signal.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../effects/engine.rkt"
         "../effects/panel.rkt"
         "../bootstrap/panel.rkt"
         "../chrome/slot.rkt"
         "../projection/render.rkt"
         "../plugins/docs/plugin.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt"
         "../dispatch/hooks.rkt"
         "../model/face-layer.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt")

(define editor-rid (region-id 1))
(define docs-rid (region-id 2))
(define completion-rid (region-id 3))
(define did (doc-id 1))
(define vid (view-id 1))

(define program
  (string-join
   '(";; comment line"
     "(define (square x) \"s\" 42)"
     "(define (square-two y) (square y))")
   "\n"))

;;; ════════════════ 夹具：一个 editor + 一个 docs 面板 ════════════════

(define (make-world [text program] [path "/tmp/lab.rkt"] [name "lab.rkt"])
  (define engine (make-engine))
  (void (engine-create-doc! engine did name text))
  (void (engine-create-view! engine vid did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did
                                  (make-doc-meta name #:path path
                                                 #:saved-version
                                                 (engine-view-doc-version
                                                  (make-engine-view engine) did)))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws editor-rid
                                     (region editor-rid (list (view-member vid)) vid 'editor))])
      ws))
  (define lay
    (make-split 'lr
                (list (make-leaf editor-rid (flex 1))
                      (make-leaf docs-rid (flex 1)))
                (flex 1)))
  (define s0 (make-state #:workspace (struct-copy workspace ws [layout lay])
                         #:ids (make-id-counter 2 2 3 1)))
  (define s1 (install-docs-panel! engine s0 docs-rid))
  (define s1b (install-completion-popup! engine s1 completion-rid))
  ;; 文档面板初始收起（和 demo 一致）
  (define s1c (state-workspace* s1b (λ (ws)
                                      (struct-copy workspace ws
                                                   [layout (tree-hide (workspace-layout ws) docs-rid)]))))
  (define s2 (startup! editor-env engine (state-set-focus s1c vid)))
  (values engine s2))

(define (feed engine s . evs)
  (transition-state (process-events editor-env engine (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c) (app:key-event (key c 'ctrl)))
;; C-c 是前缀：C-c / 补全，C-c h 文档
(define cl-slash (list (ctrl 'c) (app:key-event (key '/))))
(define cl-h (list (ctrl 'c) (app:key-event (key 'h))))

(define (buffer-of engine) (engine-doc-buffer engine did))
;; 现在是**分层**的：cell 上是 face 结构（fg / bg / attrs），
;; 所以断言按分量来（`fg-at` / `bg-at`），而不是整 face 名。
(define (face-at engine line col) (buffer-face-at (buffer-of engine) line col))
(define (component getter engine line col)
  (define f (face-at engine line col))
  (and f (if (symbol? f) (and (eq? getter face-fg) f) (getter f))))
(define (fg-at engine line col) (component face-fg engine line col))
(define (bg-at engine line col) (component face-bg engine line col))
(define (col-of line sub)
  (define m (regexp-match-positions (regexp (regexp-quote sub)) line))
  (and m (caar m)))
(define (lines-of engine) (string-split (buffer-string (buffer-of engine)) "\n"))

;;; ════════════════ 1. 语法高亮 ════════════════

(let-values ([(engine s0) (make-world)])
  (define l0 (list-ref (lines-of engine) 0))
  (define l1 (list-ref (lines-of engine) 1))
  (check-eq? (fg-at engine 0 (col-of l0 "comment")) 'fg-syntax-comment)
  (check-eq? (fg-at engine 1 (col-of l1 "define")) 'fg-syntax-def)
  (check-eq? (fg-at engine 1 (col-of l1 "\"s\"")) 'fg-syntax-string)
  (check-eq? (fg-at engine 1 (col-of l1 "42")) 'fg-syntax-number)
  ;; 括号本身没有语法前景，但有**另一个插件的背景层**（两个插件协作用例）
  (check-false (fg-at engine 1 0))
  (check-eq? (bg-at engine 1 0) 'bg-depth-1)
  ;; 同一格上两个分量同时存在：define 有前景（语法层）+ 背景（深度层）
  (check-eq? (fg-at engine 1 (col-of l1 "define")) 'fg-syntax-def)
  (check-eq? (bg-at engine 1 (col-of l1 "define")) 'bg-depth-1)

  ;; 上色不改“文档版本”，所以文档不会因此变脏
  (define dm (workspace-doc (state-workspace s0) did))
  (check-true (engine-version=? (doc-meta-saved-version dm)
                                (engine-view-doc-version (make-engine-view engine) did)))

  ;; 编辑：插入一个关键字，after-edit 后重新上色
  (define s1 (feed engine s0 (plain #\space) (plain #\() (plain #\i) (plain #\f)))
  (define new-line (list-ref (lines-of engine) 0))
  (check-eq? (fg-at engine 0 (col-of new-line "if")) 'fg-syntax-control))

;; 同词着色 / 当前词背景（edit4 的 word-color + words）
(let-values ([(engine s0) (make-world)])
  (define l1 (list-ref (lines-of engine) 1))
  (define c (col-of l1 "square"))
  (check-true (regexp-match? #rx"^fg-word-" (symbol->string (fg-at engine 1 c))))
  (define s1 (apply feed engine s0 (app:key-event (key 'down))
                    (for/list ([_ (in-range c)]) (app:key-event (key 'right)))))
  (void s1)
  (check-eq? (bg-at engine 1 c) 'bg-word-mark))

;; 插件按文件类型启用：非 Racket 文件（.txt / mode 'text）不上色
(let* ([engine (make-engine)]
       [did2 (doc-id 1)]
       [vid2 (view-id 1)]
       [rid2 (region-id 1)])
  (void (engine-create-doc! engine did2 "notes" ";; not racket\n(define x 1)"))
  (void (engine-create-view! engine vid2 did2))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did2 (make-doc-meta "notes" #:path "/tmp/notes.txt"))]
           [ws (workspace-add-view ws vid2 (view-meta did2 (hash)))]
           [ws (workspace-add-region ws rid2
                                     (region rid2 (list (view-member vid2)) vid2 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid2)])))
  (define st (startup! editor-env engine (state-set-focus (make-state #:workspace ws) vid2)))
  (void st)
  (check-false (buffer-face-at (engine-doc-buffer engine did2) 1 1)   ; "define" 不上色
               "非 .rkt 文件不应高亮"))

;;; ════════════════ 2. 补全（C-c / 弹窗 + 临时键表） ════════════════
;;
;; 注意：光标 / 文本在 engine 里（State 只存 id），所以用例必须**顺序**推进，
;; 不能拿旧的 state 再喂新事件。

(define (popup-open? s) (completion-open? s))
(define (in-popup-mode? s)
  (and (memq 'completion-popup (input-modes (state-input s))) #t))
;; 弹窗内容是**文档**：候选 = 行，选中 = 文档光标行
(define (popup-lines* engine s)
  (string-split (or (engine-view-view-text (make-engine-view engine)
                                           (completion-popup-view s))
                    "")
                "\n"))
(define (popup-sel engine s)
  (engine-view-view-point-line (make-engine-view engine) (completion-popup-view s)))

(let-values ([(engine s0) (make-world)])
  ;; 光标走 Home/End + Down 到第 3 行行尾，再输入前缀 "squ"
  (define s1 (feed engine s0 (app:key-event (key 'end))
                   (app:key-event (key 'down)) (app:key-event (key 'home))
                   (app:key-event (key 'down)) (app:key-event (key 'home))
                   (app:key-event (key 'end))))
  (define s2 (feed engine s1 (plain #\s) (plain #\q) (plain #\u)))
  (check-equal? (list-ref (lines-of engine) 2) "(define (square-two y) (square y))squ")

  ;; C-c / ：开弹窗，**不改文本**，并把临时键表挂到 input.modes
  (define s3 (apply feed engine s2 cl-slash))
  (check-true (popup-open? s3))
  (check-true (in-popup-mode? s3))
  (check-equal? (popup-sel engine s3) 0)
  (check-true (for/or ([l (in-list (popup-lines* engine s3))]) (string-contains? l "square")))
  (check-equal? (list-ref (lines-of engine) 2) "(define (square-two y) (square y))squ")

  ;; Down / Up 被临时键表接住：移动选择而不是移动光标
  (define s4 (feed engine s3 (app:key-event (key 'down))))
  (check-equal? (popup-sel engine s4) 1)
  (check-equal? (engine-view-view-point-column (make-engine-view engine) vid) 37)
  (define s5 (feed engine s4 (app:key-event (key 'up))))
  (check-equal? (popup-sel engine s5) 0)

  ;; Enter：接受选中候选，关弹窗 + 摘掉临时键表
  (define s6 (feed engine s5 (app:key-event (key 'enter))))
  (check-false (popup-open? s6))
  (check-false (in-popup-mode? s6))
  (check-equal? (list-ref (lines-of engine) 2) "(define (square-two y) (square y))square")

  ;; 再按 C-c / ：前缀变成 "square"，Esc 取消后文本不变
  (define s7 (apply feed engine s6 cl-slash))
  (check-true (popup-open? s7))
  (define s8 (feed engine s7 (app:key-event (key 'escape))))
  (check-false (popup-open? s8))
  (check-false (in-popup-mode? s8))
  (check-equal? (list-ref (lines-of engine) 2) "(define (square-two y) (square y))square")

  ;; 弹窗开着时继续打字：弹窗关掉，字符照常插入
  (define s9 (apply feed engine s8 cl-slash))
  (check-true (popup-open? s9))
  (define s10 (feed engine s9 (plain #\x)))
  (check-false (popup-open? s10))
  (check-false (in-popup-mode? s10))
  (check-true (string-suffix? (list-ref (lines-of engine) 2) "squarex"))

  ;; 关掉之后 Down 恢复成“移动光标”（模态已摘）
  (define s11 (feed engine s10 (app:key-event (key 'up))))
  (check-false (popup-open? s11)))

;; require 的模块导出（worker 的 completion-exports）：racket/list 的 first
(let-values ([(engine s0) (make-world "#lang racket/base\n(require racket/list)\n"
                                      "/tmp/imports.rkt" "imports.rkt")])
  (define s1 (feed engine s0 (app:key-event (key 'end))
                   (app:key-event (key 'down)) (app:key-event (key 'end))
                   (app:key-event (key 'down)) (app:key-event (key 'end))))
  (define s2 (feed engine s1 (plain #\f) (plain #\i) (plain #\r)))
  (define s3 (apply feed engine s2 cl-slash))
  (check-true (completion-open? s3))
  (check-true (for/or ([l (in-list (popup-lines* engine s3))])
                (string-contains? l "first"))))

;; 没有候选 / 光标处没有词 -> 只提示，不开弹窗
(let-values ([(engine s0) (make-world)])
  (define s1 (apply feed engine s0 cl-slash))                  ; 光标在 1:1 的 "(" 上
  (check-false (popup-open? s1))
  (check-true (or (string-contains? (chrome-message (state-chrome s1)) "no word at point")
                  (string-contains? (chrome-message (state-chrome s1)) "no match")))
  (check-equal? (list-ref (lines-of engine) 0) ";; comment line"))

;;; ════════════════ 2b. 点击落点（嵌套布局里要点到编辑器，不是侧栏） ════════════════

;; 复现 lab 的结构：侧栏（文件树面板）| 编辑器；status 一行；docs 面板在 status 下面。
;; 曾经因为“面板先占了 doc/view id 1”导致点哪都落到侧栏（表现：只能点到行尾）。
(define clk-sbar-rid (region-id 10))
(define clk-ed-rid (region-id 11))
(define clk-ch-rid (region-id 12))
(define clk-docs-rid (region-id 13))
(define clk-did (doc-id 1))
(define clk-vid (view-id 1))
(define clk-engine (make-engine))
(void (engine-create-doc! clk-engine clk-did "m.rkt"
                          (string-join (make-list 12 "0123456789") "\n")))
(void (engine-create-view! clk-engine clk-vid clk-did))
(define clk-ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws clk-did
                                (make-doc-meta "m.rkt" #:path "/tmp/m.rkt"
                                               #:saved-version
                                               (engine-view-doc-version
                                                (make-engine-view clk-engine) clk-did)))]
         [ws (workspace-add-view ws clk-vid (view-meta clk-did (hash)))]
         [ws (workspace-add-region ws clk-ed-rid
                                   (region clk-ed-rid (list (view-member clk-vid)) clk-vid 'editor))])
    ws))
(define clk-s0 (make-state #:workspace clk-ws #:ids (make-id-counter 2 2 14 1)
                           #:window (make-window 30 110)))
(define clk-s1 (install-filetree-panel! clk-engine clk-s0 clk-sbar-rid (current-directory)))
(define clk-s2 (install-docs-panel! clk-engine clk-s1 clk-docs-rid))
(define clk-s3 (install-chrome! clk-engine clk-s2 clk-ch-rid))
(define clk-lay
  (make-split 'lr
              (list (make-leaf clk-sbar-rid (fixed 26) #:borders '(right))
                    (make-split 'tb
                                (list (make-split 'tb
                                                  (list (make-leaf clk-ed-rid (flex 1))
                                                        (make-leaf clk-ch-rid (fixed 1) #:borders '()))
                                                  (flex 1))
                                      (make-leaf clk-docs-rid (fixed 8) #:borders '(up)))
                                (flex 1)))
              (flex 1)))
(define clk-s4
  (state-workspace*
   clk-s3
   (λ (ws)
     (struct-copy workspace ws
                  [layout (tree-hide clk-lay clk-docs-rid)]))))
(define clk-s5 (state-set-focus clk-s4 clk-vid))

;; 一帧：投影 -> 同步 view 尺寸（真实 app 由 run-frame 做）
(define-values (_clk-ps clk-placements) (project-frame clk-s5 clk-engine))
(engine-sync-views! clk-engine clk-placements)

; 编辑器内容区从 (row 1, col 27) 开始；屏幕 (4, 37) -> 内容 (3, 10) -> 文档 (3, 10)
(define clk-row 4)
(define clk-col (+ 27 10))
(define clk-s6
  (transition-state
   (process-events editor-env clk-engine (make-async-channel) clk-s5
                   (list (app:mouse-event (mouse 'press 'left) clk-row clk-col)
                         (app:mouse-event (mouse 'release 'left) clk-row clk-col)))))
(check-equal? (state-focus clk-s6) clk-vid)
(check-equal? (engine-view-view-point (make-engine-view clk-engine) clk-vid) (point 3 10))

;;; ════════════════ 2c. 打开底部面板后：焦点 view 被夹回窗口 ════════════════

;; 光标在最后一行时打开 docs（编辑区变矮），下一帧 sync 之后光标必须仍然可见。
(let-values ([(engine s0) (make-world)])
  (define ev (make-engine-view engine))
  ;; 先走一帧，让 view 有真实尺寸
  (define-values (_p pl) (project-frame s0 engine))
  (engine-sync-views! engine pl)
  ;; 光标移到最后一行
  ;; 光标移到最后一行，并站在 "define" 里面（没有标识符就不会开面板）
  (define s1 (apply feed engine s0
                    (append (for/list ([_ (in-range 3)]) (app:key-event (key 'down)))
                            (for/list ([_ (in-range 3)]) (app:key-event (key 'right))))))
  (check-equal? (engine-view-view-point-line (make-engine-view engine) vid) 2)
  ;; 打开底部 docs 面板（布局变化）
  (define s2 (apply feed engine s1 cl-h))
  (check-true (docs-open? s2))
  ;; 下一帧：投影 -> sync（尺寸变了 -> engine 里会 view-ensure!）
  (define-values (_p2 pl2) (project-frame s2 engine))
  (engine-sync-views! engine pl2)
  (define v (engine-view-object engine vid))
  (define top (view-top-line v))
  (define h (view-height v))
  (check-true (<= top (engine-view-view-point-line (make-engine-view engine) vid)))
  (check-true (< (engine-view-view-point-line (make-engine-view engine) vid) (+ top h))))

;;; ════════════════ 3. 文档面板 ════════════════

(define (docs-text engine s)
  (let ([dvid (docs-panel-view s)])
    (and dvid (engine-view-view-text (make-engine-view engine) dvid))))

(let-values ([(engine s0) (make-world)])
  ;; 光标放到第 2 行 "square" 里面（不用鼠标：headless 里 view 没有尺寸，落点不可靠）
  (define rights (for/list ([_ (in-range 12)]) (app:key-event (key 'right))))
  (define s1 (apply feed engine s0 (app:key-event (key 'down)) rights))
  (check-false (docs-open? s1))                                ; 初始收起

  (define s2 (apply feed engine s1 cl-h))                      ; C-c h
  (check-true (docs-open? s2))
  (check-true (string-contains? (docs-text engine s2) "square"))

  ;; 光标移到 "define" -> after-nav 刷新
  (define s3 (feed engine s2 (app:key-event (key 'home))))
  (define s3b (apply feed engine s3 (for/list ([_ (in-range 3)]) (app:key-event (key 'right)))))
  (check-true (docs-open? s3b))
  (check-true (string-contains? (docs-text engine s3b) "syntax"))

  ;; 面板不会自动收起：焦点离开编辑器也照样在
  (define s4 (transition-state
              (run-hooks editor-env (make-engine-view engine)
                         (transition-pure
                          (state-emit (state-set-focus s3b #f) 'focus-changed (list #f))))))
  (check-true (docs-open? s4))
  ;; 只有再按 C-c h 才关
  (define s5 (apply feed engine s4 cl-h))
  (check-false (docs-open? s5))
  ;; 焦点回到编辑器后，再按一次又打开（光标还停在 "define" 上）
  (define s6 (apply feed engine (state-set-focus s5 vid) cl-h))
  (check-true (docs-open? s6)))

;; 内置表里没有、本文件也没有的标识符 -> 不打开面板，只提示
(let-values ([(engine s0) (make-world)])
  (define s1 (feed engine s0 (app:key-event (key 'down))
                   (app:key-event (key 'end))))
  (define s2 (feed engine s1 (plain #\space) (plain #\z) (plain #\z) (plain #\z)))
  (define s3 (apply feed engine s2 cl-h))
  (check-false (docs-open? s3))
  (check-true (string-contains? (chrome-message (state-chrome s3)) "no docs for")))
