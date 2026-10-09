#lang racket

;;; edit/command/command.rkt —— 命令层：会话状态 + 纯命令转换
;;;
;;; document / view 真身仓是 core 的 **editor**（编辑器层）：
;;; 文档、视图、选区 / 视口、历史，以及「同文档视图同步」
;;; （editor-view-install! 内自动 rebase / clamp）都在 core。
;;;
;;; edit 只在其上加 core 没有的三样 + 一样展示态：
;;;     layout         可嵌套布局代数（叶子是 vid 引用，只算几何）
;;;     focus          焦点
;;;     doc-keymaps    did -> 键表（命令挂在 document 上）
;;;     presentations  每个 vid 的显隐 / 层深（渲染关注）
;;;
;;; document 命令直接转发 core 的编辑命令（editor-view-insert! 等）：
;;; 改文档 + 记历史 + 同文档视图 rebase/clamp 全由 core 完成，edit 不管同步。
;;;
;;; step 是纯转换 session × cmd -> session；副作用（读事件 / 写屏）在 edit/tui.rkt。
;;; 内嵌的 core editor 骨架不可变、内部 box 可变，所以 step 返回新 session 即可。

(require "../../core/editor.rkt"
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt")

;;; ---------- 会话 ----------

;; 每个 vid 的展示态（core 的 view 不含这两样）。
(struct presentation (depth visible?) #:transparent)

;; 层深命名常量：只表达**视图之间**的叠放。
(define layer-base 0)

(struct session (ed layout bindings presentations focus width height quit? keys doc-keymaps)
  #:transparent)
;; ed            : core editor（文档 / 视图真身仓）
;; layout        : 布局定义树（leaf(vid)/slot/split/stack/at）
;; bindings      : slot-id -> node
;; presentations : (hash vid -> presentation)
;; focus         : focus
;; width height  : 屏幕尺寸
;; quit?         : 退出标志
;; keys          : (listof keymap)  全局键表叠
;; doc-keymaps   : (hash did -> keymap)  文档级键表

(provide (struct-out session) (struct-out presentation)
         layer-base
         session-new
         session-views session-rectangles session-screen session-patch
         session-focus-vid session-focused-did session-set-focus
         session-presentation session-set-presentation session-set-visible
         session-doc-keys session-doc-add-key
         session-open-document session-add-document session-add-view
         (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-toggle)
         (struct-out cmd-quit) (struct-out cmd-resize)
         (struct-out cmd-insert) (struct-out cmd-delete) (struct-out cmd-backspace)
         (struct-out cmd-undo) (struct-out cmd-redo)
         step)

;; 建一个空 session（layout / bindings 可先给 #f，之后再 struct-copy 填）。
(define (session-new ed layout bindings focus width height [keys '()])
  (session ed layout bindings (hash) focus width height #f keys (hash)))

;;; ---------- 展示态 ----------

(define (session-presentation s vid)
  (hash-ref (session-presentations s) vid (presentation layer-base #t)))
(define (session-set-presentation s vid p)
  (struct-copy session s [presentations (hash-set (session-presentations s) vid p)]))
(define (session-set-visible s vid on?)
  (session-set-presentation s vid
    (struct-copy presentation (session-presentation s vid) [visible? on?])))

;;; ---------- 几何：布局摊平 ----------

;; layout-place -> (listof placed)。可见性由 presentations 决定（隐藏的不占位）。
(define (session-views s)
  (layout-place (session-layout s) (session-bindings s)
                (lambda (vid) (presentation-visible? (session-presentation s vid)))
                (area 0 0 (session-width s) (session-height s))))

;; placed -> core rectangle（补上深层）。
(define (session-rectangles s)
  (for/list ([p (in-list (session-views s))])
    (define vid (placed-vid p))
    (rectangle vid (placed-x p) (placed-y p) (placed-w p) (placed-h p)
               (presentation-depth (session-presentation s vid)))))

(define (session-focus-vid s) (focus-target (session-focus s)))
(define (session-set-focus s f) (struct-copy session s [focus f]))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

;;; ---------- 渲染（core 负责单视图渲染 + 多视图合成 + 增量） ----------

(define (session-screen s)
  (editor-render-layout (session-ed s) (session-rectangles s)
                        (session-focus-vid s) (session-width s) (session-height s)))

;; 增量：旧帧 + 本帧 -> (values 新帧 render selection)。
(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)))

;; 本帧几何落到各 view 的视口尺寸（ensure / 上下移动用；幂等）。
(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 文档 / 视图结构操作 ----------

;; 开一个 document（可同时给它键表）。→ (values session did)
(define (session-open-document s doc [keys (kbd)])
  (define-values (ed* did) (editor-add-document (session-ed s) doc))
  (values (struct-copy session s
            [ed ed*]
            [doc-keymaps (hash-set (session-doc-keymaps s) did keys)])
          did))

;; 一步建「文档 + 视图」。→ (values session did vid)
(define (session-add-document s doc width height
                              #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* did) (editor-add-document (session-ed s) doc))
  (define-values (ed** vid) (editor-add-view ed* did width height
                                             #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s
            [ed ed**]
            [doc-keymaps (hash-set (session-doc-keymaps s) did (kbd))])
          did vid))

;; 给已有 document 加一个 view。→ (values session vid)
(define (session-add-view s did width height
                          #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* vid) (editor-add-view (session-ed s) did width height
                                            #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s [ed ed*]) vid))

;;; ---------- 文档级键表（命令挂在 document 上） ----------

(define (session-doc-keys s did) (hash-ref (session-doc-keymaps s) did (kbd)))
(define (session-doc-add-key s did binding spec)
  (struct-copy session s
    [doc-keymaps (hash-set (session-doc-keymaps s) did
                           (keymap-add (hash-ref (session-doc-keymaps s) did (kbd))
                                       binding spec))]))

;;; ---------- 命令 ----------

(struct cmd-focus (dir) #:transparent)      ; dir : 'left 'right 'up 'down
(struct cmd-scroll (n) #:transparent)       ; 滚焦点视图 n 个视觉行
(struct cmd-toggle (slot) #:transparent)    ; 切换 bindings 里某个洞（叶）的显隐
(struct cmd-quit () #:transparent)
(struct cmd-resize (w h) #:transparent)

;; document 命令（转发 core）
(struct cmd-insert (text) #:transparent)
(struct cmd-delete () #:transparent)
(struct cmd-backspace () #:transparent)
(struct cmd-undo () #:transparent)
(struct cmd-redo () #:transparent)

;;; ---------- 纯转换 ----------

(define (step s cmd)
  (sync-layout! s)                                   ; 本帧几何 -> 视口尺寸
  (define vid (session-focus-vid s))
  (cond
    [(cmd-focus? cmd)
     (session-set-focus s (focus-move (session-views s) (session-focus s) (cmd-focus-dir cmd)))]

    [(cmd-scroll? cmd)
     (if vid (begin (editor-view-scroll! (session-ed s) vid (cmd-scroll-n cmd)) s) s)]

    [(cmd-toggle? cmd)
     (define node (hash-ref (session-bindings s) (cmd-toggle-slot cmd) #f))
     (define tvid (and (leaf? node) (leaf-vid node)))
     (if tvid
         (session-set-visible s tvid (not (presentation-visible? (session-presentation s tvid))))
         s)]

    [(cmd-resize? cmd)
     (struct-copy session s [width (cmd-resize-w cmd)] [height (cmd-resize-h cmd)])]

    [(cmd-quit? cmd) (struct-copy session s [quit? #t])]

    ;; ---- document 命令：改 core 真身，同文档视图同步由 core 完成 ----
    [(cmd-insert? cmd)
     (when vid (editor-view-insert! (session-ed s) vid (cmd-insert-text cmd)))
     s]
    [(cmd-delete? cmd)
     (when vid (editor-view-delete! (session-ed s) vid))
     s]
    [(cmd-backspace? cmd)
     (when vid (editor-view-backspace! (session-ed s) vid))
     s]
    [(cmd-undo? cmd)
     (when vid (editor-view-undo! (session-ed s) vid))
     s]
    [(cmd-redo? cmd)
     (when vid (editor-view-redo! (session-ed s) vid))
     s]

    [else s]))
