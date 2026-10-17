#lang racket

;;; bootstrap/commands.rkt —— 默认命令（纯 transition 构造器）
;;;
;;; 命令只吃 ctx，返回 transition；需要写 core 的地方发 effect。
;;; 这一块是“可替换的默认值”，不是框架核心：用户/插件可以覆盖同名 command-id。

(provide default-command-table
         split-view-command
         close-view-command
         focus-move-command)

(require "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/role.rkt"
         "../projection/geometry.rkt"
         "../../core/editor/ops.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../dispatch/context.rkt")

;;; ════════════════ 小工具 ════════════════

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (view-subject ctx)
  (define s (ctx-subject ctx))
  (and (view-id? s) s))

(define (frame-area state)
  (rect 0 0 (window-cols (state-window state)) (window-rows (state-window state))))

;;; ════════════════ 基础命令 ════════════════

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "nav: no view")))))

(define (insert-command text)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (insert-text-effect vid text)))
             (message ctx "insert: no view")))))

(define (edit-command op)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (edit-effect vid op)))
             (message ctx "edit: no view")))))

(define (undo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (undo-effect vid)))
             (message ctx "undo: no view")))))

(define (redo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (redo-effect vid)))
             (message ctx "redo: no view")))))

(define (quit-command)
  (cmd (λ (ctx) (transition-pure (state-mark-quit (ctx-state ctx))))))

;;; ════════════════ 切分 / 关闭 ════════════════

(define (split-view-command dir)
  (cmd (λ (ctx) (split-view ctx dir))))

(define (split-view ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (cond
    [(not (and did reg)) (message ctx "split: no view")]
    [(not (role-splittable? (environment-role (ctx-env ctx) role)))
     (message ctx "split: region not splittable")]
    [else
     (define rid (region-key reg))
     (define leaf (tree-find (workspace-layout ws) rid))
     (define borders (if leaf (leaf-borders leaf) leaf-borders-all))
     (transition s
                 (list (open-view-effect did
                                          (λ (s* nvid)
                                            (mount-split s* rid borders nvid dir)))))]))
(define (axis/side dir)
  (case dir
    [(left)  (values 'lr 'before)]
    [(right) (values 'lr 'after)]
    [(up)    (values 'tb 'before)]
    [(down)  (values 'tb 'after)]
    [else (error 'split-view "未知方向：~a" dir)]))

(define (mount-split s source-rid borders nvid dir)
  (define-values (axis side) (axis/side dir))
  (define-values (nrid s1) (state-next-id s 'region))
  (define ws (state-workspace s1))
  (define source-reg (workspace-region ws source-rid))
  (define new-reg (region nrid
                          (list (view-member nvid))
                          nvid
                          (if source-reg (region-role source-reg) 'editor)))
  (define ws* (workspace-add-region ws nrid new-reg))
  (define layout* (tree-split (workspace-layout ws*) source-rid axis nrid
                              #:side side #:borders borders))
  (define s2 (state-set-workspace s1 (struct-copy workspace ws* [layout layout*])))
  (transition-pure (state-set-focus s2 nvid)))

(define (close-view-command)
  (cmd (λ (ctx) (close-view ctx))))

(define (close-view ctx)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (define policy (if role (role-close-policy (environment-role (ctx-env ctx) role)) 'ignore))
  (cond
    [(not vid) (message ctx "close: no view")]
    [(eq? policy 'ignore) (message ctx "close: region ignores close")]
    [else
     (define source-rid (and reg (region-key reg)))
     (define ws* (workspace-remove-view ws vid))
     ;; 优先同 region 里的其它 view，其次任意剩余 view。
     (define fallback
       (or (and source-rid
                (for/first ([v (in-list (workspace-region-views ws* source-rid))]) v))
           (for/first ([v (in-hash-keys (workspace-views ws*))]) v)))
     (define ws** (workspace-set-focus* ws* fallback #:push? #f))
     (transition (state-set-workspace s ws**)
                 (list (close-view-effect vid)))]))

;;; ════════════════ 焦点移动 ════════════════

(define (focus-move-command dir)
  (cmd (λ (ctx) (focus-move ctx dir))))

(define (focus-move ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (cond
    [(not reg) (message ctx "focus: no view")]
    [else
     (define-values (rps _cuts)
       (geometry-solve (workspace-layout ws) (frame-area s)))
     ;; 用 region id 当 panel 的 owner，走 core 的方向导航。
     (define panels
       (for/list ([rp (in-list rps)])
         (make-panel (region-panel-region rp)
                     (region-panel-rect rp)
                     (region-panel-borders rp))))
     (define from
       (for/first ([p (in-list panels)]
                   #:when (equal? (panel-view p) (region-key reg)))
         p))
     (define nbr (and from (panel-neighbor panels from dir)))
     (define target-rid (and nbr (panel-view nbr)))
     (define target-reg (and target-rid (workspace-region ws target-rid)))
     (define target-vid (and target-reg (workspace-region-active ws target-rid)))
     (if (view-id? target-vid)
         (transition-pure (state-set-focus s target-vid))
         (message ctx "focus: no neighbor view"))]))

;;; ════════════════ 默认命令表 ════════════════

(define (default-command-table)
  (hash 'quit         (quit-command)
        'nav-left     (nav-command 'left)
        'nav-right    (nav-command 'right)
        'nav-up       (nav-command 'up)
        'nav-down     (nav-command 'down)
        'nav-home     (nav-command 'home)
        'nav-end      (nav-command 'end)
        'insert-enter (insert-command "\n")
        'backspace    (edit-command (op-backspace))
        'delete       (edit-command (op-delete))
        'undo         (undo-command)
        'redo         (redo-command)
        'split-right  (split-view-command 'right)
        'split-down   (split-view-command 'down)
        'close-view   (close-view-command)
        'focus-left   (focus-move-command 'left)
        'focus-right  (focus-move-command 'right)
        'focus-up     (focus-move-command 'up)
        'focus-down   (focus-move-command 'down)))
