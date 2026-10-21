#lang racket

;;; edit-tui-rebuild/app/step.rkt —— event -> (values state actions)（纯）
;;;
;;; 这里只做三件事：
;;;   1. 选命令表（overlays > 焦点 resource 的 per-doc 表 > 焦点 panel 的表）
;;;   2. 按键 / 鼠标 / 粘贴 -> 命令或 action
;;;   3. 需要改焦点、改消息时走 app/state.rkt 的状态迁移
;;;
;;; 不碰 engine、不碰 IO；action 由 runtime 解释。

(require "../core/skeleton.rkt"
         "../chrome/api.rkt"
         "keymap.rkt"
         "../edit/api.rkt"
         "event.rkt"
         "placement.rkt"
         "state.rkt"
         "action.rkt")

(provide step)

;;; ════════════════ 命令表 ════════════════

(define (clear-pending state)
  (struct-copy app-state state [pending '()]))

;; 拖选是鼠标手势：非鼠标事件打断它（选区留在 view 里，不会丢）。
(define (clear-select-drag state)
  (if (app-state-select-drag state)
      (struct-copy app-state state [select-drag #f])
      state))

;; flash 只存在到下一次 step；命令 / action 在本次 step 里重新设置。
(define (clear-flash state)
  (if (string=? (app-state-flash state) "")
      state
      (struct-copy app-state state [flash ""])))

;; 两模式：
;;   叠加：非输入态 = 动态 overlays over (per-doc / panel base) over keymap overlays
;;         局部键表优先于全局键表；placement 等动态模态仍在最上层。
;;   替换：输入态直接返回 keymap 的 input-stack（模态独占，不拼 overlays）
;; stack 查找 unbound 会继续查下一张表；如果输入态也叠加 overlay，
;; C-q / C-w 这类未绑定键就会穿透到全局命令。
(define (current-command-stack state)
  (define km (app-state-keymap state))
  (cond
    [(input-active? state) (keymap-input-stack km)]
    [else
     (define rid (app-state-focus-resource state))
     (define base
       (cond
         [rid (or (resource-command-stack (app-state-resources state) rid)
                  command-table-stack-empty)]
         [else
          ;; 同一 panel 可以挂多个 tab：先按 active view-id 找局部表，
          ;; 再回退到 panel-id（filetree 等单 tab 面板）。
          (define vid (app-state-focus-view-id state))
          (or (and vid
                   (hash-ref (app-state-panel-stacks state) vid #f))
              (hash-ref (app-state-panel-stacks state)
                        (app-state-focus-panel-id state)
                        command-table-stack-empty))]))
     (command-table-stack-over
      (app-state-overlays state)
      (command-table-stack-over base (keymap-overlays km)))]))

(define (run-command state value)
  (if (procedure? value)
      (value state)
      (values (app-state-with-flash state (format "not a command: ~a" value))
              '())))

;;; ════════════════ 键盘 ════════════════

(define (dispatch-key state ev)
  (define tok (key-event-token ev))
  (define pending (app-state-pending state))
  (define seq (append pending (list tok)))
  (let-values ([(status value) (command-table-stack-lookup (current-command-stack state) seq)])
    (case status
      [(command)
       (run-command (clear-pending state) value)]
      [(prefix)
       (values (struct-copy app-state state [pending seq]) '())]
      [else
       ;; 表里没有：输入态 -> input-self-insert（总是吞下），否则可打印字符
       ;; 自插入到焦点 editor；有前缀则中断前缀。
       (define s1 (clear-pending state))
       (define-values (s2 actions)
         (cond
           [(input-active? s1) (input-self-insert s1 tok)]
           [(null? pending) (edit-self-insert s1 tok)]
           [else (values #f '())]))
       (cond
         [s2 (values s2 actions)]
         [else
          (values (app-state-with-flash
                   s1
                   (format "unbound: ~a" (string-join (map key->string seq) " ")))
                  '())])])))

;;; ════════════════ 鼠标 ════════════════

;; 点击内容区 -> 把该 panel 的 active view 光标设到点击处。
;; 所有面板一视同仁：文件树也只是普通 buffer，光标归 view 所有。
;; press 同时记下 select-drag：之后 move 在同一个 view 里扩展选区，
;; release 结束（选区留在 view 里，不需要额外 action）。
(define (content-point-actions state pid row col extend?)
  (define p (app-state-panel state pid))
  (define vid (and p (panel-view p)))
  (if vid
      (list (view-action 'point vid (list row col extend?)))
      '()))

;; 拖动选区：把指针坐标换算成「被拖 panel 内容区」的相对坐标。
;; 指针跑出内容区时坐标可能为负 / 超出；engine 的 point 会夹到最近有效行/列。
;; 上下越界时先滚一行，让选区能继续延伸到屏幕外（每次 move 滚一行）。
(define (drag-select-actions state sd row col)
  (define vid (select-drag-view-id sd))
  (define content (layout-content-rect (app-state-layout state)
                                       (app-state-area state)
                                       (select-drag-panel-id sd)))
  (cond
    [(or (not vid) (not content)) '()]
    [else
     (define r (- row (rect-y content)))
     (define c (- col (rect-x content)))
     (define scrolls
       (cond
         [(< r 0) (list (view-action 'scroll vid -1))]
         [(>= r (rect-h content)) (list (view-action 'scroll vid 1))]
         [else '()]))
     (append scrolls (list (view-action 'point vid (list r c #t))))]))

(define (dispatch-mouse state ev #:solution [solution #f])
  (define row (mouse-event-row ev))
  (define col (mouse-event-col ev))
  (define area (app-state-area state))
  (define layout (app-state-layout state))
  (define config (app-state-layout-config state))
  (case (mouse-event-token ev)
    [(press)
     ;; 一次 layout-hit 同时得到 panel / seam / 内容区，避免重复 solve。
     (define h (layout-hit layout area row col #:solution solution))
     (define hit-id (hit-panel-id h))
     (define placement-id (app-state-placement state))
     ;; 新的一次 press 结束上一次拖选（半截拖选不延续）。
     (define state* (struct-copy app-state state [select-drag #f]))
     (cond
       ;; placement 中点到 editor：直接放入
       [(and placement-id
             hit-id
             (eq? (panel-kind (layout-panel layout hit-id)) 'editor))
        (place-into-panel state* hit-id)]
       [else
        (define seam (hit-seam h))
        (cond
          [seam
           (define d (layout-seam-drag-start layout area row col
                                            #:config config
                                            #:seam seam
                                            #:solution (hit-solution h)))
           (values (struct-copy app-state state* [drag d]) '())]
          [else
           ;; 内容区（去掉边框）：聚焦 + 光标落点 + 开始拖选；边框 / 角上只改焦点。
           (define cid (hit-content-id h))
           (cond
             [cid
              (define s1 (app-state-set-focus-panel state* cid))
              (define vid (app-state-focus-view-id s1))
              (cond
                [(not vid) (values s1 '())]
                [else
                 (values (struct-copy app-state s1
                                      [select-drag (select-drag cid vid)])
                         (content-point-actions s1 cid
                                                (hit-content-row h)
                                                (hit-content-col h)
                                                #f))])]
             [else
              (define id (and hit-id
                              (layout-panel-focusable? layout config hit-id)
                              hit-id))
              (if id
                  (values (app-state-set-focus-panel state* id) '())
                  (values state* '()))])])])]
    [(move)
     (define d (app-state-drag state))
     (define sd (app-state-select-drag state))
     (cond
       [d
        (define-values (layout* ok?)
          (layout-seam-drag-move layout area d row col #:config config))
        (values (if ok? (struct-copy app-state state [layout layout*]) state)
                '())]
       ;; 拖选：选择留在按下的 panel 里，指针移到别的 panel 也不换目标。
       [sd (values state (drag-select-actions state sd row col))]
       [else (values state '())])]
    [(release)
     ;; 松手结束拖动：接缝 drag 与选区 drag 都清；选区本身留在 view 里。
     (values (struct-copy app-state state [drag #f] [select-drag #f]) '())]
    [(scroll-up scroll-down)
     ;; 滚轮滚指针下的 panel；不改焦点，不移动光标。
     (define id (hit-panel-id (layout-hit layout area row col #:solution solution)))
     (define p (and id (app-state-panel state id)))
     (define vid (and p (panel-view p)))
     (cond
       [(not vid) (values state '())]
       [else
        (define delta (if (eq? (mouse-event-token ev) 'scroll-up) -3 3))
        (values state (list (view-action 'scroll vid delta)))])]
    [else
     (define h (layout-hit layout area row col #:solution solution))
     (define hit-id (hit-panel-id h))
     (define id (and hit-id (layout-panel-focusable? layout config hit-id) hit-id))
     (if id
         (values (app-state-set-focus-panel state id) '())
         (values state '()))]))

;;; ════════════════ 粘贴 / 尺寸 / 总入口 ════════════════

(define (dispatch-paste state ev)
  ;; 只有焦点在 editor 上才允许粘贴；action 里传原始字节，engine 写 buffer 时解码。
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (app-state-with-flash state "paste: 焦点不是 editor") '())]
    [else
     (values state (list (view-action 'paste vid (paste-event-bytes ev))))]))

(define (dispatch-resize state ev)
  (values (struct-copy app-state state
                       [area (rect 0 0 (resize-event-cols ev) (resize-event-rows ev))])
          '()))

;; 入口 / 出口都维护「prompt / request <-> 输入栏」这个不变量，
;; 并在输入激活时做抢占：
;;   - key / paste 交给输入栏；
;;   - 其他事件先取消本次输入，再处理该事件。
(define (step state ev #:solution [solution #f])
  (define state0 (clear-flash state))
  ;; pending 只对连续按键有意义；mouse / paste / resize / quit 等事件
  ;; 打断半截序列，否则下一次按键会拼上旧前缀。
  (define state0* (if (key-event? ev) state0 (clear-pending state0)))
  ;; 鼠标事件保留拖选状态（move 继续扩展）；其他事件结束拖选。
  (define state0** (if (mouse-event? ev) state0* (clear-select-drag state0*)))
  (define-values (s0 a0) (input-reconcile state0**))
  (cond
    [(and (input-active? s0)
          (not (key-event? ev))
          (not (paste-event? ev)))
     (define-values (s1 a1) (input-interrupt s0 'cancelled))
     (define-values (s2 a2) (step-dispatch s1 ev #:solution solution))
     (define-values (s3 a3) (input-reconcile s2))
     (values s3 (append a0 a1 a2 a3))]
    [else
     (define-values (s1 a1) (step-dispatch s0 ev #:solution solution))
     (define-values (s2 a2) (input-reconcile s1))
     (values s2 (append a0 a1 a2))]))

(define (step-dispatch state ev #:solution [solution #f])
  (cond
    ;; 键盘不在这里分流：输入态由 current-command-stack 选 keymap 的 input-stack。
    ;; 粘贴不是键序列，仍直接交给输入栏。
    [(and (paste-event? ev) (input-active? state))
     (input-handle-paste state ev)]
    [else
     (case (event-kind ev)
       [(key) (dispatch-key state ev)]
       [(mouse) (dispatch-mouse state ev #:solution solution)]
       [(paste) (dispatch-paste state ev)]
       [(resize) (dispatch-resize state ev)]
       [(quit) (values (struct-copy app-state state [quit? #t]) '())]
       [(internal)
        (case (internal-event-kind ev)
          [(quit) (values (struct-copy app-state state [quit? #t]) '())]
          [else (values state '())])]
       [else (values state '())])]))
