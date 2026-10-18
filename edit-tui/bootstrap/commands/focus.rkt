#lang racket

;;; layer  : bootstrap/commands
;;; effect : 焦点命令只改 State；鼠标命令发 select-effect（拖选）
;;;
;;; focus : 用 geometry 的 region 面板做方向导航，落到邻居 region 的 active view。
;;; 鼠标  : press 聚焦 + 把光标落到点击位置（screen->point）；
;;;         drag 从按下时的 anchor 拖选。
;;;
;;; 鼠标点空白 panel（没有成员）时只聚焦，不落点。

(provide focus-move-command
         pointer-press-command
         pointer-drag-command)

(require (prefix-in app: "../../base/event.rkt")
         "../../base/id.rkt"
         "../../base/effect.rkt"
         "../../base/transition.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/input.rkt"
         "../../env/command.rkt"
         "../../effects/engine.rkt"
         "../../projection/geometry.rkt"
         "../../dispatch/context.rkt"
         "../../../core/editor/ops.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/selection.rkt"
         "../../../core/view/base/rect.rkt"
         "util.rkt")

;;; ════════════════ 焦点移动 ════════════════

(define (focus-move-command dir)
  (cmd (λ (ctx) (focus-move ctx dir))))

(define (focus-move ctx dir)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (region-subject ctx))
  (cond
    [(input-busy? ctx) (message ctx "focus: input active")]
    [(not reg) (message ctx "focus: no region")]
    [else
     (define target-rid (region-neighbor (workspace-layout ws)
                                         (frame-area s)
                                         (region-key reg)
                                         dir))
     (define target-reg (and target-rid (workspace-region ws target-rid)))
     (define target-vid (and target-reg (workspace-region-active ws target-rid)))
     (cond
       [(not target-rid) (message ctx "focus: no neighbor")]
       ;; 落到邻居的 active view；邻居是空 region 就把焦点放在 region 上。
       [(view-id? target-vid) (transition-pure (state-set-focus s target-vid))]
       [else (transition-pure (state-set-focus s target-rid))])]))

;;; ════════════════ 鼠标：点击落点 / 拖选 ════════════════

;; 屏幕 (row,col) -> 焦点 view 的文档 point。
;; view 的屏幕坐标是「panel 内容区」内的坐标，所以要先减去内容区原点。
(define (screen->point ctx vid row col)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (workspace-view-region ws vid))
  (define eview (ctx-engine ctx))
  (cond
    [(not (and reg eview)) #f]
    [else
     (define area (frame-area s))
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
     (define rp
       (for/first ([p (in-list rps)]
                   #:when (equal? (region-panel-region p) (region-key reg)))
         p))
     (cond
       [(not rp) #f]
       [else
        (define content (region-panel-content rp))
        (define-values (line c)
          (engine-view-view-screen-position->point
           eview vid
           (- row (rect-y content))
           (- col (rect-x content))))
        (and line (point line c))])]))

(define (pointer-press-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (define ev (ctx-event ctx))
         (if (not (and vid (app:mouse-event? ev)))
             (transition-pure (ctx-state ctx))
             (let ([pt (screen->point ctx vid
                                      (app:mouse-event-row ev)
                                      (app:mouse-event-col ev))])
               (if (not pt)
                   (transition-pure (state-set-focus (ctx-state ctx) vid))
                   (let* ([s1 (state-set-focus (ctx-state ctx) vid)]
                          [s2 (state-input*
                               s1
                               (λ (i)
                                 (input-set-gesture
                                  i (make-gesture 'select vid (list vid pt)))))] )
                     (transition s2
                                 (list (select-effect
                                        vid
                                        (selections-one (caret pt))))))))))))

(define (pointer-drag-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define d (input-gesture (state-input s)))
         (define ev (ctx-event ctx))
         (if (not (and (gesture? d) (eq? (gesture-kind d) 'select)))
             (transition-pure s)
             (let* ([vid (gesture-owner d)]
                    [anchor (cadr (gesture-data d))]
                    [pt (and (app:mouse-event? ev)
                             (screen->point ctx vid
                                            (app:mouse-event-row ev)
                                            (app:mouse-event-col ev)))])
               (if pt
                   (transition s
                               (list (select-effect
                                      vid
                                      (selections-one (selection anchor pt)))))
                   (transition-pure s)))))))
