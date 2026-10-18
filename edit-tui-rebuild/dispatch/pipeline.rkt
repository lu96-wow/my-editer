#lang racket

;;; dispatch/pipeline.rkt —— 事件 → Transition 的统一派发（纯）
;;; layer  : dispatch
;;; effect : 无（事件 -> transition；不执行 effect）

;;;   dispatch env state event [#:subject s] [#:engine e] -> transition
;;;
;;; 关键点：
;;;   · 键盘 / 鼠标共用“规则 → command-id → command”的路径；
;;;   · keymap 叶子存 command-id，命令实现由 env 查；
;;;   · subject 由事件决定：键盘 = focus，鼠标 = 命中（调用方给），手势 = owner；
;;;   · 未命中时用 mode.fallback 决定“插入文本 / 忽略”，不再把插入写死在 step；
;;;   · 所有状态变化仍走纯 State 变换，文本写入用 effect。
;;;
;;; 暂定：
;;;   · 鼠标 hit-test 在 projection/geometry（块 5），这里只接收 subject；
;;;   · 输入栏是普通 document；输入文本通过 input mode 的编辑命令进入 buffer，
;;;     提交时由 input-submit 读 buffer 字符串匹配输入命令。
;;;   · seam 拖动是 gesture scope，等 geometry 块接。

(provide dispatch
         dispatch-key
         dispatch-mouse)

(require "../base/id.rkt"
         "../base/event.rkt"
         "../base/effect.rkt"
         "../base/keymap.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../model/layout.rkt"
         "../projection/geometry.rkt"
         "../env/environment.rkt"
         "../env/role.rkt"
         "../env/mode.rkt"
         "../env/command.rkt"
         "../command/key.rkt"
         "../command/mouse.rkt"
         "context.rkt"
         "rules.rkt")

;;; ════════════════ 入口 ════════════════

(define (dispatch env state event #:subject [subject #f] #:engine [engine #f])
  ;; 操作会清掉上一次的提示：消息只活到“下一次用户动作”。
  ;; 拖拽 move / resize / 内部事件不清，避免拖动时消息闪没。
  (define state*
    (if (message-expiring-event? event)
        (state-chrome* state chrome-clear-message)
        state))
  (define t
    (case (event-kind event)
      [(key)      (dispatch-key env state* event (or subject (state-focus state*)) engine)]
      [(mouse)    (dispatch-mouse env state* event subject engine)]
      [(resize)   (dispatch-resize state* event)]
      [(paste)    (dispatch-paste state* event subject)]
      ;;
      ;; 内部事件 / tick 不是“命令输入”，而是**信号**：
      ;; 统一走 `standard-signal-points` 一套注册表（env.hooks），不另设 handler 表。
      ;;   internal : point = (internal-event-kind ev)，args = payload
      ;;   tick     : point = 'tick，args = (list id)
      [(internal) (transition-pure
                   (state-emit state
                               (internal-event-kind event)
                               (internal-event-payload event)))]
      [(tick)     (transition-pure
                   (state-emit state 'tick (list (tick-event-id event))))]
      [(quit)     (transition-pure (state-mark-quit state*))]
      [else       (transition-pure state*)]))
  ;; 焦点变化记成信号（命令自己不需要知道谁关心焦点）。
  (define s-pre (state-focus state*))
  (define s-post (state-focus (transition-state t)))
  (define t*
    (if (equal? s-pre s-post)
        t
        (transition (state-emit (transition-state t) 'focus-changed (list s-post))
                    (transition-effects t))))
  ;; 每次 dispatch 都推进 revision：运行时据此重绘。
  (transition (state-bump-revision (transition-state t*))
              (transition-effects t*)))

;; 哪些事件算“用户动作”（清旧消息）。
(define (message-expiring-event? event)
  (case (event-kind event)
    [(key paste) #t]
    [(mouse) (memq (mouse-action (mouse-event-token event)) '(press release))]
    [else #f]))

;;; ════════════════ 键盘 ════════════════

(define (dispatch-key env state event subject engine)
  (define tok (key-event-token event))
  (define in (state-input state))
  (define pending (input-pending in))
  (cond
    ;; pending 非空：先单独查 prefix 表（不拼进序列）
    [(pair? pending)
     (define-values (st v) (lookup-rules (prefix-rules env) (list tok)))
     (cond
       [(eq? st 'leaf)
        (run-command env
                     (state-input* state input-clear-pending)
                     event subject engine v)]
       [else (dispatch-key-normal env state event subject engine
                                  (append pending (list tok)))])]
    [else
     (dispatch-key-normal env state event subject engine (list tok))]))

(define (dispatch-key-normal env state event subject engine seq)
  (define-values (st v) (lookup-rules (rules-for env state subject) seq))
  (case st
    [(leaf)
     (run-command env
                  (state-input* state input-clear-pending)
                  event subject engine v)]
    [(prefix)
     (transition-pure (state-input* state (λ (i) (input-set-pending i seq))))]
    [else
     ;; 未命中：丢掉 pending（不然会卡在 C-x 前缀里），并按完整序列报告。
     (dispatch-unbound env (state-input* state input-clear-pending) seq subject)]))

;;; ════════════════ 鼠标 ════════════════

(define (dispatch-mouse env state event subject engine)
  (if (state-input-active? state)
      (transition-pure state)          ; 输入栏模态：输入中忽略鼠标
      (dispatch-mouse* env state event subject engine)))

(define (dispatch-mouse* env state event subject engine)
  (define tok (mouse-event-token event))
  (define action (mouse-action tok))
  (define gesture (input-gesture (state-input state)))
  (define row (mouse-event-row event))
  (define col (mouse-event-col event))
  (define ws (state-workspace state))
  (define win (state-window state))
  (define area (window-area win))
  (define-values (_rps cuts) (geometry-solve (workspace-layout ws) area))
  (define seams (cuts-at cuts row col))
  (define subject*
    (if (and (memq action '(move release)) gesture (gesture-owner gesture))
        (gesture-owner gesture)
        subject))
  (cond
    ;; 1) 缝：布局 chrome，优先于命令
    [(and (eq? action 'press) (pair? seams))
     (transition-pure
      (state-input* state
                     (λ (i)
                       (input-set-gesture
                        i (make-gesture 'seam #f
                                        (list row col seams (workspace-layout ws)))))))]
    ;; 2) 正在拖缝
    [(and (eq? action 'move) (gesture? gesture) (eq? (gesture-kind gesture) 'seam))
     (match-define (list r0 c0 cuts0 lay0) (gesture-data gesture))
     (define lay*
       (for/fold ([t lay0]) ([cut (in-list cuts0)])
         (define delta (if (eq? (cut-axis cut) 'lr) (- col c0) (- row r0)))
         (tree-resize-seam t cut delta)))
     (transition-pure
      (state-workspace* state (λ (w) (struct-copy workspace w [layout lay*]))))]
    [(and (eq? action 'release) (gesture? gesture) (eq? (gesture-kind gesture) 'seam))
     (transition-pure (state-input* state (λ (i) (input-set-gesture i #f))))]
    [else
     (define-values (st v)
       (if subject*
           (lookup-rules (rules-for env state subject*) (list tok))
           (values 'unbound #f)))
     (cond
       [(eq? st 'leaf)
        (run-command env state event subject* engine v)]
       [else
        (case action
          [(press)
           (if (focusable-subject? env state subject*)
               (transition-pure (state-set-focus state subject*))
               (transition-pure state))]
          [(release)
           (transition-pure (state-input* state (λ (i) (input-set-gesture i #f))))]
          [(scroll)
           (if subject*
               (transition state (list (scroll-effect subject*
                                                      (if (eq? (mouse-button tok) 'up) -3 3))))
               (transition-pure state))]
          [else (transition-pure state)])])]))

;;; ════════════════ 其它事件 ════════════════

(define (dispatch-resize state event)
  (transition-pure
   (state-set-window state (make-window (resize-event-rows event)
                                        (resize-event-cols event)))))

(define (dispatch-paste state event subject)
  (if subject
      (transition state (list (insert-text-effect subject (paste-event-text event))))
      (notice state "paste: no subject")))

;;; ════════════════ 命令执行 ════════════════

(define (run-command env state event subject engine id)
  (define c (environment-command env id))
  (cond
    [(not c)
     (notice state (format "unknown command: ~a" id))]
    [(command-needs-input? c)
     ;; rebuild 的输入栏是 document；旧 command #:input 不再驱动 state prompt。
     (notice state (format "command ~a needs input; use input document" id))]
    [else
     (define ctx (make-ctx env state event subject engine))
     (define t (command-run/ctx c ctx))
     (unless (transition? t)
       (error 'dispatch "命令 ~a 的 run 没有返回 transition：~a" id t))
     t]))

;;; ════════════════ fallback ════════════════

;; 未命中：按 subject 的 mode.fallback 决定。
;;   'insert + 可打印字符 -> insert-text-effect
;;   'ignore / 不可打印     -> chrome 消息
;;
;; seq 是**完整**尝试序列（可能有前缀）：带前缀时绝不插入字符，
;; 否则 C-x p 会在文档里留一个 p —— 只报告 "unbound: C-x p"。
(define (dispatch-unbound env state seq subject)
  (define mode-id (subject-mode-id state subject))
  (define fallback (if mode-id (mode-fallback (environment-mode env mode-id)) 'ignore))
  (define tok (last seq))
  (define text (token-text tok))
  (cond
    [(> (length seq) 1)
     (notice state (format "unbound: ~a" (sequence->string seq)))]
    [(and (eq? fallback 'insert) text subject)
     (transition state (list (insert-text-effect subject text)))]
    [else
     (notice state (format "unbound: ~a" (sequence->string seq)))]))

;; 键序列 -> 显示串：C-x p
(define (sequence->string seq)
  (string-join (for/list ([t (in-list seq)]) (key->string t)) " "))

;; 可打印字符（不含 Ctrl/Alt）。shift 暂不参与大小写，后续由 key 层规范化。
(define (token-text tok)
  (and (key? tok)
       (not (memq 'ctrl (key-mods tok)))
       (not (memq 'alt (key-mods tok)))
       (let ([n (key-name tok)])
         (cond
           [(eq? n 'space) " "]
           [(and (symbol? n) (= 1 (string-length (symbol->string n))))
            (symbol->string n)]
           [else #f]))))

;; 主体（view）所在区域的 role 是否可聚焦。
;; subject 可以是 view（有文档）或 region（空面板 / 刚拆出来的空窗口）。
(define (focusable-subject? env state subject)
  (define ws (state-workspace state))
  (define r (cond
              [(view-id? subject) (workspace-view-region ws subject)]
              [(region-id? subject) (workspace-region ws subject)]
              [else #f]))
  (and r (role-focusable? (environment-role env (region-role r)))))

(define (notice state text)
  (transition-pure
   (state-chrome* state (λ (c) (chrome-set-message c text)))))
