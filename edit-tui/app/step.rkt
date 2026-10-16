#lang racket

;;; app/step.rkt —— 纯状态转移
;;;
;;;   world-step  : world × event      → (values world' (listof intent))
;;;   world-step* : world × (listof event) → 同上（左折，异步结果搭同一班车）
;;;
;;; 本文件**不碰终端、不 put-bytes、不起线程**。所有副作用都退回成 intent。
;;; 唯一允许的“读”是 core 的纯查询（panel-screen-position->point 等）——
;;; 它们只读 view 的视口状态，不改任何东西。
;;;
;;; 事件入口按语义分派，不经过 build-input 的回调优先级（那会引入隐式的
;;; “谁先消费”规则）；这里顺序显式、可读、可测：
;;;
;;;   app-event（内部） > key > mouse > resize > paste > null > 其它

(require tui
         "world.rkt"
         "intent.rkt"
         "doc-kind.rkt"
         "panel-ref.rkt"
         "../command/main.rkt"
         "../layout/main.rkt"
         "../../core/editor.rkt")

(provide world-step world-step*)

;;; ════════════════════════ 顶层分派 ════════════════════════

(define (world-step w ev)
  (match ev
    [(app-event kind payload) (step-internal w kind payload)]
    [(key-event _ _)          (step-key w ev)]
    [(mouse-event _ _ _ _ _)  (step-mouse w ev)]
    [(resize-event rows cols) (values (world-resize w cols rows) '())]
    [(paste-event _ text)     (step-insert w text)]
    [(null-event)             (values w '())]
    [_                        (values w '())]))

;; 批量：把异步 / 外部回投的内部事件与终端事件一起折叠。
;; 暂定：inbox 的排空由 loop 做（终端事件到达时搭车），所以这里只负责折。
(define (world-step* w evs)
  (for/fold ([w w] [is '()]) ([ev (in-list evs)])
    (define-values (w* is*) (world-step w ev))
    (values w* (append is is*))))

;;; ════════════════════════ 内部事件 ════════════════════════
;;; 默认只认识 'task-done（spawn 的回投）。其余交给 world 的 internal 注册表：
;;; 插件加一种内部事件 = 往 internal hash 里加一条，不改本文件。
(define (step-internal w kind payload)
  (case kind
    [(task-done)
     ;; payload = (list id value)。暂定：只落到 status；扩展点留给 internal。
     (match-define (list id value) payload)
     (values (mark-dirty (struct-copy world w
                                      [status (format "task ~a done: ~a" id value)]))
             '())]
    [else
     (define h (hash-ref (world-internal w) kind #f))
     (if h (h w payload) (values w '()))]))

;;; ════════════════════════ 键盘 ════════════════════════

(define (step-key w ev)
  (define tok (event->key ev))
  (define seq (append (world-pending w) (list tok)))
  (define-values (status cmd) (lookup-token w seq))
  (case status
    [(command)
     ;; 命中叶子：先清前缀（并清掉前缀提示 status），再执行命令。
     (run-command (struct-copy world w [pending '()] [status ""]) cmd ev)]
    [(prefix)
     ;; 命中前缀：存进 world（纯数据），状态行显示待续序列。
     (values (mark-dirty (struct-copy world w
                                      [pending seq]
                                      [status (pending->string seq)]))
             '())]
    [else
     ;; 未命中：清前缀。可打印字符 → 插入文本；否则记状态行。
     (define w1 (struct-copy world w [pending '()]))
     (define k (key-event-key ev))
     (define m (key-event-mods ev))
     (cond
       [(and (char? k) (not (mods-ctrl? m)) (not (mods-alt? m)))
        (step-insert w1 (string k))]
       [else
        (values w1
                (list (modify (λ (w)
                                (struct-copy world w
                                             [status (format "unbound: ~a"
                                                             (key->string tok))])))))])]))

;;; 活动表：按优先级逐张查，第一个非 unbound 胜出（= 覆盖语义）。
;;;
;;; 层序（高 → 低）：
;;;   mode 表  >  document 自己的层（per-doc 插件）  >  focus 的 kind 默认表  >  全局表
;;;
;;; “subject 的 kind 默认表”就是命令表穿透到 document 类型的地方。
;;; subject 是**命令作用的主体身份（panel-ref）**：
;;;   · 键盘：focus ref；
;;;   · 鼠标：命中的 panel 的 ref（点哪个文档就用哪个文档的表）；
;;;   · 拖动中：拖动主体 ref（否则指针移出面板就断表）。
;;; ref 在此解析成当帧 view 后再按 buffer 的 kind 取表。
(define (active-tables w [subject-ref (world-focus w)])
  (define subject (world-ref->view w subject-ref))
  (append
   (for/list ([m (in-list (world-modes w))] #:when (mode-table m))
     (mode-table m))
   (view-tables subject)                        ; document 自己的覆盖层（最优先，可插拔）
   (list (kind->keytable (view-kind subject)))   ; 类型默认表（穿透到 document 类型）
   (list (world-keytable w))))                  ; 全局表（最低）

;; subject-ref = #f → 用 focus ref。
(define (lookup-token w seq [subject-ref #f])
  (define-values (s c)
    (for/fold ([s 'unbound] [c #f])
              ([t (in-list (active-tables w (or subject-ref (world-focus w))))])
      (if (eq? s 'unbound)
          (keytable-lookup t seq)
          (values s c))))
  (values s c))

(define (pending->string seq)
  (string-join (map key->string seq) " "))

;;; ════════════════════════ 插入文本（键盘 / 粘贴共用） ════════════════════════

(define (step-insert w text)
  (define v (world-focus-view w))
  (if v
      (values (mark-dirty w) (list (edit v (op-type text))))
      (values w '())))

;;; ════════════════════════ 鼠标 ════════════════════════
;;;
;;; 本函数只做**通用路由** + 布局通用机制：
;;;   · 拖缝（resize）属于布局 chrome，不属于任何 document 类型 → 总是 step 处理，优先；
;;;   · 其余鼠标事件 → 查 active-tables（键鼠同一套）。「点击落点」「起选」等
;;;     行为已下放成类型表里的 `(mouse 'press 'left)` / `(mouse 'move #f)` 命令
;;;     （见 base-keys.rkt 的 pointer-keys）。
;;;   · 找不到命令时的**兜底极简**：点面板只聚焦，其它无副作用。
;;;
;;; 关键：鼠标命令按**主体 ref 的类型表**解析（不是 focus）：
;;;   · 点哪个 panel 就取哪个 panel 的 ref；
;;;   · 拖动中用拖动主体（drag-subject 是 ref），否则指针移出面板就断表。
;;; `drag` 只有 kind='seam 是 step 认识的；其余 drag 由类型命令解释。
(define (step-mouse w ev)
  (define action (mouse-event-action ev))
  (define button (mouse-event-button ev))
  (define-values (row col) (mouse-position ev))
  ;; 一次 solve 拿全：平铺 panel / 同序 ref / 缝（避免重复解）。
  (define lay (world-layout w))
  (define area (world-area w))
  (define floats (world-floats w))
  (define-values (placements tiled cuts) (tree-solve lay area))
  (define ps (append tiled (floats->panels floats)))
  (define refs (placements->refs placements floats))
  (define p (panel-at ps row col))
  (define hit-ref (panel->ref ps refs p))
  (define-values (l c)
    (if (and p (not (panel-empty? p)))
        (panel-screen-position->point p row col)
        (values #f #f)))
  (define doc-point (and l (point l c)))
  (define d (world-drag w))
  (define subject-ref
    (cond
      [(and (memq action '(move release)) (drag? d) (drag-subject d)) (drag-subject d)]
      [hit-ref hit-ref]
      [else #f]))
  (define seams (cuts-at cuts row col))
  (cond
    ;; 1) 缝：布局 chrome，优先于任何命令
    [(and (eq? action 'press) (pair? seams))
     (values (mark-dirty (struct-copy world w
                                      [drag (drag 'seam #f (list row col seams (world-layout w)))]))
             '())]
    ;; 2) 正在拖缝 → 继续通用拖动（不让类型的 move 命令截断）
    [(and (eq? action 'move) (drag? d) (eq? (drag-kind d) 'seam))
     (step-mouse-seam-move w row col d)]
    ;; 3) 其余：查表（主体 ref 决定用哪张类型表），命中即跑命令
    [else
     (define token (event->mouse ev))
     (define-values (st cmd)
       ;; subject-ref 为 #f（点空白 / 无主体）就不查表，避免意外回落到 focus 的表。
       (if (and token subject-ref) (lookup-token w (list token) subject-ref) (values 'unbound #f)))
     (cond
       [(and (eq? st 'command) cmd) (run-command w cmd ev subject-ref p doc-point)]
       [(eq? action 'press)   (step-mouse-default-press w hit-ref)]
       [(eq? action 'release) (values (mark-dirty (struct-copy world w [drag #f])) '())]
       [(eq? action 'scroll)  (step-mouse-scroll w button p)]
       [else (values w '())])]))

;; 兜底：点面板只聚焦（不落点 —— 落点是类型命令的事）；点空白清焦点。
(define (step-mouse-default-press w hit-ref)
  (values (world-focus-on w hit-ref) '()))

;; 拖缝（通用）：按格数重分。
(define (step-mouse-seam-move w row col d)
  (match-define (drag _ _ data) d)
  (match-define (list r0 c0 cs lay0) data)
  (define lay*
    (for/fold ([t lay0]) ([cut (in-list cs)])
      (define delta (if (eq? (cut-axis cut) 'lr) (- col c0) (- row r0)))
      (tree-resize-seam t cut delta)))
  (values (mark-dirty (struct-copy world w [layout lay*])) '()))

;; 滚轮兜底：滚光标所在面板（类型表可覆盖 `(mouse 'scroll …)`）。
(define (step-mouse-scroll w button p)
  (cond
    [(and p (not (panel-empty? p)))
     (values (mark-dirty w)
             (list (scroll (panel-view p) (if (eq? button 'up) -3 3))))]
    [else (values w '())]))

;;; ════════════════════════ 命令执行 ════════════════════════

(define (run-command w cmd ev [ref #f] [panel #f] [doc-point #f])
  (cond
    [(command-needs-input? cmd)
     ;; 暂定：带 input spec 的命令先只提示；minibuffer 模式接上后在这里 push mode。
     (values (mark-dirty (struct-copy world w
                                      [status (input-prompt (command-input cmd))]))
             '())]
    [else
     (define c (make-ctx w ev ref panel doc-point))
     (define intents (->intent-list ((command-run cmd) c)))
     (define-values (w* effs) (apply-state-intents w intents))
     ;; 视觉类效果（edit/select/scroll/invoke/open-doc）后补一个重绘标记：
     ;; 命令不必自己操心 dirty，也不引入 redraw intent（不冗余）。
     (values (if (ormap visual-effect? effs) (mark-dirty w*) w*) effs)]))

;; ref #f → 用 focus；view 由 ref 当帧解析。
(define (make-ctx w ev [ref #f] [panel #f] [doc-point #f])
  (define r (or ref (world-focus w)))
  (ctx w ev r (world-ref->view w r) panel doc-point))

;; 归一：命令返回 intent / (listof intent) / void，都收成 list。
(define (->intent-list x)
  (cond [(list? x) x]
        [(intent? x) (list x)]
        [else '()]))

;; 折叠状态意图，返回新的 world 与效果意图（保持顺序）。
(define (apply-state-intents w intents)
  (define w*
    (for/fold ([w w]) ([i (in-list intents)] #:when (update? i))
      (define w2 ((update-f i) w))
      (if (update-dirty? i) (mark-dirty w2) w2)))
  (values w* (filter effect? intents)))

(define (visual-effect? i)
  (or (edit? i) (select? i) (scroll? i) (invoke? i) (open-doc? i)))
