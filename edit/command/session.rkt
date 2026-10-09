#lang racket

;;; edit/command/session.rkt —— 会话实现（功能实现）
;;;
;;; document / view 真身仓是 core 的 **editor**（编辑器层）：文档、视图、选区 / 视口、
;;; 历史，以及「同文档视图同步」都在 core。本模块是**唯一 require core** 的 edit 模块。
;;;
;;; edit 在其上加：
;;;     layout         可嵌套布局代数（叶子是 vid 引用，只算几何）
;;;     presentations  每个 vid 的显隐 / 层深
;;;     panels         状态窗口：视图 + 内容生成函数 + 自己的键表
;;;     focus          输入焦点；edit-vid 为粘性活动编辑视图
;;;     doc-keymaps    did -> 键表（命令挂在 document 上）
;;;     handlers       命令处理链（feature 各自挂自己的命令）
;;;     prompt         输入行状态（label + 提交回调）
;;;
;;; 命令层（command.rkt）只 require 其中「命令需要的那几个操作函数」，不碰其余实现。
;;; 操作原语是纯转换 session -> session；内嵌 core editor 骨架不可变、内部 box 可变。

(require "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/point.rkt"
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt")

;;; ---------- 值 ----------

;; 每个 vid 的展示态（core 的 view 不含这两样）。
(struct presentation (depth visible?) #:transparent)
(define layer-base 0)

;; 状态窗口：一块停靠视图 + 内容生成函数 + 自己的键表。
(struct panel (id vid refresh keys group) #:transparent)
;; id      : symbol
;; refresh : (session -> (or/c document #f))   ; #f = 不自动刷新（如输入行）
;; group   : symbol | #f   同一组（同位置）互斥；#f = 独占一行的窗口（如状态 / 输入）

;; 输入行状态。
(struct prompt (vid label on-submit) #:transparent)
;; on-submit : (session string -> session)

(struct session
  (ed layout bindings presentations panels
   focus edit-vid width height quit? keys doc-keymaps handlers prompt prefix)
  #:transparent)
;; ed            : core editor（文档 / 视图真身仓）
;; layout        : 布局定义树（leaf(vid)/slot/split/stack/at）
;; bindings      : slot-id -> node
;; presentations : (hash vid -> presentation)
;; panels        : (listof panel)
;; focus         : focus（输入焦点）
;; edit-vid      : 活动编辑视图（粘性）
;; width height  : 屏幕尺寸
;; quit?         : 退出标志
;; keys          : (listof keymap)  全局键表叠
;; doc-keymaps   : (hash did -> keymap)
;; handlers      : (listof (session cmd -> (or/c session #f)))  命令处理链
;; prompt        : prompt | #f
;; prefix        : prefix | #f   活动前缀（多键序列）

(provide (struct-out session) (struct-out presentation) (struct-out panel) (struct-out prompt)
         layer-base
         session-new session-blank
         ;; 派生 / 渲染
         session-views session-rectangles session-screen session-patch session-refresh
         session-focus-vid session-edit-vid session-focused-did session-set-focus
         session-prefix session-set-prefix
         ;; 展示态
         session-presentation session-set-presentation session-set-visible
         ;; 状态窗口
         session-add-panel session-panel session-panel-vid session-vid-keys
         session-panel-dids session-dock-vid? session-panel-swap
         session-add-handler
         ;; 文档级键表
         session-doc-keys session-doc-add-key
         ;; 构造 / 结构操作
         session-open-document session-add-document session-add-view
         session-split-view session-close-view session-close-document session-show-view
         ;; 读（供 feature 用，不暴露 core）
         session-document-ids session-view-ids-of session-document-name
         session-view-did session-view-point session-view-point-line
         ;; 输入行
         session-prompt-open session-prompt-submit session-prompt-cancel
         ;; 操作原语（命令需要的就是这几个）
         session-focus-move session-scroll session-toggle-slot
         session-resize session-quit session-nav
         session-select-all session-copy session-cut session-paste
         session-insert session-delete session-backspace
         session-undo session-redo)

;; 建一个空 session（layout / bindings 可先给 #f，之后再 struct-copy 填）。
(define (session-new ed layout bindings focus width height [keys '()])
  (session ed layout bindings (hash) '()
           focus (focus-target focus) width height #f keys (hash) '() #f #f))

;; 从头建一个空 session（内置空 editor；文档 / 视图随后用 session-open-document 加）。
(define (session-blank width height [keys '()])
  (session-new (make-blank-editor) #f #f (focus-new #f) width height keys))

;;; ---------- 展示态 ----------

(define (session-presentation s vid)
  (hash-ref (session-presentations s) vid (presentation layer-base #t)))
(define (session-set-presentation s vid p)
  (struct-copy session s [presentations (hash-set (session-presentations s) vid p)]))
(define (session-set-visible s vid on?)
  (session-set-presentation s vid
    (struct-copy presentation (session-presentation s vid) [visible? on?])))

;;; ---------- 状态窗口 ----------

(define (session-panel s vid)
  (for/first ([p (in-list (session-panels s))] #:when (eqv? vid (panel-vid p))) p))
(define (session-panel-vid s id)
  (for/first ([p (in-list (session-panels s))] #:when (eq? id (panel-id p))) (panel-vid p)))
(define (session-vid-keys s vid)
  (define p (session-panel s vid))
  (and p (panel-keys p)))
(define (session-dock-vid? s vid)
  (and vid (and (session-panel s vid) #t)))
(define (session-add-panel s p)
  (struct-copy session s [panels (append (session-panels s) (list p))]))
(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (editor-view-document-id (session-ed s) (panel-vid p))))

;; 同组（同位置）窗口互换：Tab。
;;   · 焦点在某组窗口 → 切到该组的下一个（只显它）
;;   · 焦点不在组内 → 切到第一组的下一个（默认组）
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define group
    (cond [(and curp (panel-group curp)) (panel-group curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (panel-group p))
                  (panel-group p))]))
  (cond
    [(not group) s]
    [else
     (define members (for/list ([p (in-list (session-panels s))]
                               #:when (eq? group (panel-group p))) p))
     (define idx (for/first ([p (in-list members)] [i (in-naturals)]
                             #:when (eqv? (panel-vid p) cur)) i))
     (define chosen (list-ref members (if idx (modulo (add1 idx) (length members)) 0)))
     (define cvid (panel-vid chosen))
     (define s1 (for/fold ([s s]) ([p (in-list members)])
                  (session-set-visible s (panel-vid p) (eqv? (panel-vid p) cvid))))
     (session-set-focus s1 (focus-set (session-focus s1) cvid))]))

;;; ---------- 命令处理链 ----------

(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))

;;; ---------- 几何：布局摊平 ----------

(define (session-views s)
  (layout-place (session-layout s) (session-bindings s)
                (lambda (vid) (presentation-visible? (session-presentation s vid)))
                (area 0 0 (session-width s) (session-height s))))

(define (session-rectangles s)
  (for/list ([p (in-list (session-views s))])
    (define vid (placed-vid p))
    (rectangle vid (placed-x p) (placed-y p) (placed-w p) (placed-h p)
               (presentation-depth (session-presentation s vid)))))

(define (session-focus-vid s) (focus-target (session-focus s)))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

(define (session-set-focus s f)
  (define vid (focus-target f))
  (define edit (if (and vid (not (session-dock-vid? s vid))) vid (session-edit-vid s)))
  (struct-copy session s [focus f] [edit-vid edit]))

(define (session-set-prefix s p) (struct-copy session s [prefix p]))

;;; ---------- 渲染 ----------

(define (session-screen s)
  (editor-render-layout (session-ed s) (session-rectangles s)
                        (session-focus-vid s) (session-width s) (session-height s)))

(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)))

;; 每帧刷新状态窗口内容（内容变了才 assign）。
(define (session-refresh s)
  (for ([p (in-list (session-panels s))])
    (define f (panel-refresh p))
    (when f
      (define doc (f s))
      (when doc (editor-view-assign! (session-ed s) (panel-vid p) doc))))
  s)

;; 本帧几何落到各 view 的视口尺寸（ensure / 上下移动用；幂等）。
(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 文档 / 视图结构操作 ----------

(define (session-open-document s doc [keys (kbd)] #:name [name "*scratch*"])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (values (struct-copy session s
            [ed ed*]
            [doc-keymaps (hash-set (session-doc-keymaps s) did keys)])
          did))

(define (session-add-document s doc width height
                              #:name [name "*scratch*"]
                              #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (define-values (ed** vid) (editor-add-view ed* did width height
                                             #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s
            [ed ed**]
            [doc-keymaps (hash-set (session-doc-keymaps s) did (kbd))])
          did vid))

(define (session-add-view s did width height
                          #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* vid) (editor-add-view (session-ed s) did width height
                                            #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s [ed ed*]) vid))

(define (session-show-view s vid)
  (session-set-focus s (focus-set (session-focus s) vid)))

;; 在 vid 旁按 axis 分屏出一个新视图（同文档）；焦点移到新视图。
(define (session-split-view s vid axis)
  (define ed (session-ed s))
  (define did (editor-view-document-id ed vid))
  (define w (max 5 (editor-view-width ed vid)))
  (define h (max 3 (editor-view-height ed vid)))
  (define-values (s1 nvid) (session-add-view s did w h))
  (define s2 (struct-copy session s1
               [layout (layout-split (session-layout s1) vid axis nvid)]))
  (session-show-view s2 nvid))

;; 关一个编辑视图（状态窗口不受影响）。
(define (session-close-view s vid)
  (cond
    [(session-dock-vid? s vid) s]
    [else
     (define ed (session-ed s))
     (define did (editor-view-document-id ed vid))
     (define remaining (remove vid (editor-document-view-list ed did)))
     (cond
       [(null? remaining) (session-close-document s did)]
       [else
        (define ed* (editor-close-view ed vid))
        (define s* (struct-copy session s
                     [ed ed*]
                     [layout (layout-remove (session-layout s) vid)]
                     [presentations (hash-remove (session-presentations s) vid)]))
        (if (eqv? vid (session-focus-vid s*))
            (session-show-view s* (first remaining))
            s*)])]))

;; 关一个文档（连带其所有视图）；不关状态窗口。
(define (session-close-document s did)
  (define ed (session-ed s))
  (define vids (editor-document-view-list ed did))
  (cond
    [(for/or ([v (in-list vids)]) (session-dock-vid? s v)) s]
    [else
     (define ed* (editor-close-document ed did))
     (define layout* (for/fold ([l (session-layout s)]) ([v (in-list vids)]) (layout-remove l v)))
     (define pres* (for/fold ([h (session-presentations s)]) ([v (in-list vids)]) (hash-remove h v)))
     (define s* (struct-copy session s [ed ed*] [layout layout*] [presentations pres*]))
     (define fv (session-focus-vid s*))
     (cond
       [(and fv (memv fv vids))
        (define rest (for/list ([v (in-list (editor-view-id-list ed*))]
                                #:unless (session-dock-vid? s* v)) v))
        (session-set-focus s* (focus-set (session-focus s*) (and (pair? rest) (first rest))))]
       [else s*])]))

;;; ---------- 读（供 feature 用） ----------

(define (session-document-ids s) (editor-document-id-list (session-ed s)))
(define (session-view-ids-of s did) (editor-document-view-list (session-ed s) did))
(define (session-document-name s did) (editor-document-name (session-ed s) did))
(define (session-view-did s vid) (editor-view-document-id (session-ed s) vid))
(define (session-view-point s vid) (editor-view-point (session-ed s) vid))
(define (session-view-point-line s vid) (editor-view-point-line (session-ed s) vid))

;;; ---------- 文档级键表 ----------

(define (session-doc-keys s did) (hash-ref (session-doc-keymaps s) did (kbd)))
(define (session-doc-add-key s did binding spec)
  (struct-copy session s
    [doc-keymaps (hash-set (session-doc-keymaps s) did
                           (keymap-add (hash-ref (session-doc-keymaps s) did (kbd))
                                       binding spec))]))

;;; ---------- 输入行 ----------

(define (prompt-document label)
  (define doc (document-open label))
  (when (positive? (string-length label))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length label) #t))))
  doc)

;; 打开输入行：装 label（只读）+ 空输入，显示、push 焦点、记回调。
(define (session-prompt-open s vid label on-submit)
  (define ed (session-ed s))
  (editor-view-assign! ed vid (prompt-document label))
  (editor-view-set-point! ed vid (point 0 (string-length label)))
  (define s1 (session-set-visible s vid #t))
  (define s2 (session-set-focus s1 (focus-push (session-focus s1) vid)))
  (struct-copy session s2 [prompt (prompt vid label on-submit)]))

(define (session-prompt-close s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define s1 (session-set-visible s (prompt-vid p) #f))
     (define s2 (session-set-focus s1 (focus-restore (session-focus s1))))
     (struct-copy session s2 [prompt #f])]))

;; Enter：取 label 之后的文本 → 关输入行 → 回调。
(define (session-prompt-submit s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define full (editor-view-string (session-ed s) (prompt-vid p)))
     (define label (prompt-label p))
     (define text (substring full (min (string-length label) (string-length full))
                             (string-length full)))
     ((prompt-on-submit p) (session-prompt-close s) text)]))

(define (session-prompt-cancel s) (session-prompt-close s))

;;; ---------- 操作原语 ----------

(define (with-focus-vid s proc)
  (define vid (session-focus-vid s))
  (when vid (proc vid))
  s)

(define (session-focus-move s dir)
  (session-set-focus s (focus-move (session-views s) (session-focus s) dir)))

(define (session-scroll s n)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-scroll! (session-ed s) vid n))))

;; 文本光标移动（输入行 / 状态窗口内导航）。
(define (session-nav s dir extend?)
  (sync-layout! s)
  (define ed (session-ed s))
  (with-focus-vid s
    (lambda (vid)
      (case dir
        [(left)  (editor-view-left! ed vid extend?)]
        [(right) (editor-view-right! ed vid extend?)]
        [(up)    (editor-view-up! ed vid extend?)]
        [(down)  (editor-view-down! ed vid extend?)]
        [(home)  (editor-view-home! ed vid extend?)]
        [(end)   (editor-view-end! ed vid extend?)]
        [else (error 'session-nav "未知方向: ~a（left/right/up/down/home/end）" dir)]))))

(define (session-toggle-slot s slot)
  (define node (hash-ref (session-bindings s) slot #f))
  (define vid (and (leaf? node) (leaf-vid node)))
  (if vid
      (session-set-visible s vid (not (presentation-visible? (session-presentation s vid))))
      s))

(define (session-resize s w h) (struct-copy session s [width w] [height h]))
(define (session-quit s) (struct-copy session s [quit? #t]))

;; 选区 / 剪贴板（转发 core）
(define (session-select-all s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-select-all! (session-ed s) vid))))
(define (session-copy s)
  (with-focus-vid s (lambda (vid) (editor-view-copy! (session-ed s) vid))))
(define (session-cut s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-cut! (session-ed s) vid))))
(define (session-paste s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-paste! (session-ed s) vid))))

(define (session-insert s text)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-insert! (session-ed s) vid text))))
(define (session-delete s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-delete! (session-ed s) vid))))
(define (session-backspace s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-backspace! (session-ed s) vid))))
(define (session-undo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-undo! (session-ed s) vid))))
(define (session-redo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-redo! (session-ed s) vid))))
