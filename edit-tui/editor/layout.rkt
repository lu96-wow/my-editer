#lang racket

;;; edit-tui/editor/layout.rkt —— 布局操作面
;;;
;;; 布局本身是纯值（core/layout），这里只负责：
;;;   · 把 layout 放进 core state
;;;   · split / close / focus 时创建 / 删除 engine view
;;;   · 跑 layout 扩展点
;;;
;;; 插件通过 editor/api.rkt 拿到 editor-split! / editor-close! / editor-focus!；
;;; layout-context 只在 editor/host 内部使用。鼠标与 sidebar chrome 分别在
;;; features/mouse 与 features/sidebar。

(require "../core/api.rkt"
         "../core/layout/api.rkt"
         "../core/projection/api.rkt"
         "../core/focus/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "engine/api.rkt"
         "context.rkt"
         "state.rkt"
         "resource.rkt"
         "hooks.rkt"
         "ops/surface.rkt")

(provide (struct-out layout-context)
         make-layout-context
         editor-layout-panels
         editor-focus-panel-id
         editor-focus-panel
         editor-focus-panel-kind
         editor-focus-view-id
         editor-focus-view
         editor-focus-view-if-attached!
         editor-focus-content-rect
         editor-visible-editor-panels
         editor-split!
         editor-close!
         editor-focus!
         editor-cycle-editor-view!
         editor-toggle-panel!)

;;; ════════════════ 配置 ════════════════


;;; ════════════════ 初始布局 ════════════════


;;; ════════════════ 查询 ════════════════

(define (editor-focus-panel-id state)
  (define l (state-layout state))
  (and l (layout-focus l)))

(define (editor-focus-panel state)
  (define l (state-layout state))
  (and l (layout-panel l (layout-focus l))))

(define (editor-focus-panel-kind state)
  (define p (editor-focus-panel state))
  (and p (p:panel-kind p)))

(define (editor-focus-view-id state)
  (define p (editor-focus-panel state))
  (and p (p:panel-active p)))

;; focus 一个已经挂在 panel 上的 view；detached -> attached? = #f，由调用方 placement。
(define (editor-focus-view-if-attached! ed state vid)
  (define l (state-layout state))
  (define pid (and l vid (layout-panel-for-view l vid)))
  (cond
    [(not pid) (values state '() #f)]
    [else
     (define-values (l* ok?) (layout-panel-set-active-view l pid vid))
     (define l** (if ok? (layout-set-focus l* pid) (layout-set-focus l pid)))
     (values (state-with-layout state l**) '() #t)]))

(define (editor-focus-view ed state)
  (define vid (editor-focus-view-id state))
  (and vid (engine-view-object (editor-engine ed) vid)))

;; focus panel 的内容区 rect（给 completion popup 定位）。
(define (editor-focus-content-rect state)
  (define l (state-layout state))
  (define area (state-area state))
  (define pid (editor-focus-panel-id state))
  (and l area pid (layout-content-rect l area pid)))

;; 可见 editor panel（按树序）。
(define (editor-visible-editor-panels state)
  (define l (state-layout state))
  (and l
       (for/list ([pid (in-list (layout-visible-panel-ids l))]
                  #:when (eq? (p:panel-kind (layout-panel l pid)) 'editor))
         pid)))

;; layout -> repo core panels（给 host 渲染 / 命中用）。
(define (editor-layout-panels ed state)
  (define l (state-layout state))
  (define area (state-area state))
  (and l area
       (layout->render-panels l area
                              #:view-object
                              (λ (vid) (engine-view-object (editor-engine ed) vid))
                              #:focus-panel (layout-focus l))))

;;; ════════════════ layout 扩展点 ════════════════

;; action : 'split | 'close | 'focus
(struct layout-context
  (engine
   state
   action
   from-panel
   to-panel
   dir
   result)   ; before #f；after = 新 layout | #f
  #:transparent)

(define (make-layout-context engine state action
                             #:from-panel [from #f]
                             #:to-panel [to #f]
                             #:dir [dir #f]
                             #:result [result #f])
  (layout-context engine state action from to dir result))

(define (run-before registry operation ctx state)
  (run-before-hooks registry operation ctx state))

(define (run-after registry operation ctx state)
  (run-after-hooks registry operation ctx state))

(define (flash state text)
  (values (state-with-flash state text) '()))

;;; ════════════════ split ════════════════

(define (editor-split! ed state dir)
  (define engine (editor-engine ed))
  (define l (state-layout state))
  (define from (and l (layout-focus l)))
  (define p (and from (layout-panel l from)))
  (define src-vid (and p (p:panel-active p)))
  (cond
    [(not l) (flash state "split: no layout")]
    [(not p) (flash state "split: no focused panel")]
    [(not (eq? (p:panel-kind p) 'editor)) (flash state "split: focus is not editor")]
    [(not src-vid) (flash state "split: focused panel has no view")]
    [else
     (define ctx0 (make-layout-context engine state 'split #:from-panel from #:dir dir))
     (define-values (ctx1 state1 actions1 allow?)
       (run-before (editor-registry ed) 'layout-split ctx0 state))
     (cond
       [(not allow?) (values state1 actions1)]
       [else
        (define l1 (state-layout state1))
        (define new-pid (state-next-panel-id state1))
        (define new-vid (state-next-view-id state1))
        (define-values (l2 ok?)
          (layout-split l1 from dir new-pid #:config (state-layout-config state)))
        (cond
          [(not ok?) (flash state1 "split failed")]
          [else
           ;; 新 panel 需要自己的 view；不能把一个 view 同时挂在两个 panel。
           (void (engine-create-view-from-view! engine new-vid src-vid))
           (define-values (l3 added?)
             (layout-panel-add-view l2 new-pid new-vid))
           (define l4 (layout-set-focus l3 new-pid))
           ;; split 出来的 view 也属于同一个 resource。
           (define src-r (state-resource-for-view state1 src-vid))
           (define resources*
             (if src-r
                 (resources-add-view (state-resources state1)
                                     (resource-id src-r) new-vid)
                 (state-resources state1)))
           (define state2
             (state-with-next-panel-id
              (state-with-next-view-id
               (state-with-resources
                (state-with-layout state1 l4)
                resources*)
               (add1 new-vid))
              (add1 new-pid)))
           (define ctx2
             (struct-copy layout-context ctx1
                          [state state2]
                          [to-panel new-pid]
                          [result l4]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-split ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

;;; ════════════════ close ════════════════

(define (editor-close! ed state)
  (define engine (editor-engine ed))
  (define l (state-layout state))
  (define from (and l (layout-focus l)))
  (define p (and from (layout-panel l from)))
  (define editors (editor-visible-editor-panels state))
  (cond
    [(not l) (flash state "close: no layout")]
    [(not p) (flash state "close: no focused panel")]
    [(not (eq? (p:panel-kind p) 'editor)) (flash state "close: focus is not editor")]
    [else
     (define last-editor? (<= (length editors) 1))
     (define ctx0 (make-layout-context engine state 'close #:from-panel from))
     (define-values (ctx1 state1 actions1 allow?)
       (run-before (editor-registry ed) 'layout-close ctx0 state))
     (cond
       [(not allow?) (values state1 actions1)]
       [else
        (define l1 (state-layout state1))
        ;; 还有别的 editor：删掉当前 panel。
        ;; 最后一个 editor：只清空 views，保留 panel slot；view/resource 仍可再 placement。
        (define-values (l2 ok?)
          (if last-editor?
              (layout-panel-clear-content l1 from)
              (layout-panel-remove l1 from #:config (state-layout-config state))))
        (cond
          [(not ok?) (flash state1 "close failed")]
          [else
           ;; 关闭 panel 只从布局摘掉；view / resource 仍然存在，可再 placement。
           (define state2 (state-with-layout state1 l2))
           (define ctx2
             (struct-copy layout-context ctx1 [state state2] [result l2]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-close ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

;;; ════════════════ focus ════════════════

;; 侧栏 tab：filetree <-> resources。
;; 通用 panel 显隐（docs 等）。
(define (editor-toggle-panel! ed state pid)
  (define l (state-layout state))
  (define area (state-area state))
  (cond
    [(or (not l) (not area) (not pid)) (flash state "panel: no target")]
    [else
     (define visible? (layout-panel-visible? l pid))
     (define-values (l* ok?)
       (if visible?
           (layout-panel-hide l area pid #:config (state-layout-config state))
           (layout-panel-show l area pid #:config (state-layout-config state))))
     (if ok?
         (values (state-with-layout state l*) '())
         (flash state "panel toggle failed"))]))

(define (editor-cycle-editor-view! ed state [step 1])
  (define p (editor-focus-panel state))
  (cond
    [(or (not p) (not (eq? (p:panel-kind p) 'editor)))
     (flash state "tab: focus is not editor")]
    [else
     (define l (state-layout state))
     (define-values (l* ok?)
       (layout-panel-cycle-active-view l (p:panel-id p) step))
     (if ok?
         (values (state-with-layout state l*) '())
         (flash state "tab: panel has no views"))]))


(define (editor-focus! ed state dir)
  (define l (state-layout state))
  (define area (state-area state))
  (define from (and l (layout-focus l)))
  (cond
    [(or (not l) (not area)) (flash state "focus: no layout / area")]
    [else
     (define to (layout-focus-neighbor l area (state-layout-config state) from dir))
     (cond
       [(not to) (flash state "no focus neighbor")]
       [else
        (define ctx0
          (make-layout-context (editor-engine ed) state 'focus
                               #:from-panel from #:to-panel to #:dir dir))
        (define-values (ctx1 state1 actions1 allow?)
          (run-before (editor-registry ed) 'layout-focus ctx0 state))
        (cond
          [(not allow?) (values state1 actions1)]
          [else
           (define l1 (state-layout state1))
           (define l2 (layout-set-focus l1 to))
           (define state2 (state-with-layout state1 l2))
           (define ctx2
             (struct-copy layout-context ctx1 [state state2] [result l2]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-focus ctx2 state2))
           (values state3 (append actions1 actions3))])])]))
