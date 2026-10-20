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

;; 两模式：
;;   叠加：非输入态 = 动态 overlays over keymap overlays over (per-doc / panel base)
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
          (hash-ref (app-state-panel-stacks state)
                    (app-state-focus-panel-id state)
                    command-table-stack-empty)]))
     (command-table-stack-over
      (app-state-overlays state)
      (command-table-stack-over (keymap-overlays km) base))]))

(define (run-command state value)
  (if (procedure? value)
      (value state)
      (values (app-state-with-message state (format "not a command: ~a" value))
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
          (values (app-state-with-message
                   s1
                   (format "unbound: ~a" (string-join (map key->string seq) " ")))
                  '())])])))

;;; ════════════════ 鼠标 ════════════════

;; 点击内容区 -> 把该 panel 的 active view 光标设到点击处。
;; 所有面板一视同仁：文件树也只是普通 buffer，光标归 view 所有。
(define (content-point-actions state pid row col)
  (define p (app-state-panel state pid))
  (define vid (and p (panel-view p)))
  (if vid
      (list (view-action 'point vid (list row col)))
      '()))

(define (dispatch-mouse state ev)
  (define row (mouse-event-row ev))
  (define col (mouse-event-col ev))
  (define area (app-state-area state))
  (define layout (app-state-layout state))
  (define config (app-state-layout-config state))
  (case (mouse-event-token ev)
    [(press)
     (define placement-id (app-state-placement state))
     (define hit-id (layout-panel-id-at layout area row col))
     (cond
       ;; placement 中点到 editor：直接放入
       [(and placement-id
             hit-id
             (eq? (panel-kind (layout-panel layout hit-id)) 'editor))
        (place-into-panel state hit-id)]
       [else
        (define seam (layout-seam-at layout area row col))
        (cond
          [seam
           (define d (layout-seam-drag-start layout area row col #:config config))
           (values (struct-copy app-state state [drag d]) '())]
          [else
           ;; 内容区（去掉边框）：聚焦 + 光标落点；边框 / 角上只改焦点。
           (define-values (cid c-row c-col)
             (layout-content-hit layout area row col))
           (cond
             [cid
              (define s1 (app-state-set-focus-panel state cid))
              (values s1 (content-point-actions s1 cid c-row c-col))]
             [else
              (define id (layout-focus-panel-at layout area config row col))
              (if id
                  (values (app-state-set-focus-panel state id) '())
                  (values state '()))])])])]
    [(move)
     (define d (app-state-drag state))
     (cond
       [(not d) (values state '())]
       [else
        (define-values (layout* ok?)
          (layout-seam-drag-move layout area d row col #:config config))
        (values (if ok? (struct-copy app-state state [layout layout*]) state)
                '())])]
    [(release)
     (values (struct-copy app-state state [drag #f]) '())]
    [else
     (define id (layout-focus-panel-at layout area config row col))
     (if id
         (values (app-state-set-focus-panel state id) '())
         (values state '()))]))

;;; ════════════════ 粘贴 / 尺寸 / 总入口 ════════════════

(define (dispatch-paste state ev)
  ;; 只有焦点在 editor 上才允许粘贴；action 里传原始字节，engine 写 buffer 时解码。
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (app-state-with-message state "paste: 焦点不是 editor") '())]
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
(define (step state ev)
  (define-values (s0 a0) (input-reconcile state))
  (cond
    [(and (input-active? s0)
          (not (key-event? ev))
          (not (paste-event? ev)))
     (define-values (s1 a1) (input-interrupt s0 'cancelled))
     (define-values (s2 a2) (step-dispatch s1 ev))
     (define-values (s3 a3) (input-reconcile s2))
     (values s3 (append a0 a1 a2 a3))]
    [else
     (define-values (s1 a1) (step-dispatch s0 ev))
     (define-values (s2 a2) (input-reconcile s1))
     (values s2 (append a0 a1 a2))]))

(define (step-dispatch state ev)
  (cond
    ;; 键盘不在这里分流：输入态由 current-command-stack 选 keymap 的 input-stack。
    ;; 粘贴不是键序列，仍直接交给输入栏。
    [(and (paste-event? ev) (input-active? state))
     (input-handle-paste state ev)]
    [else
     (case (event-kind ev)
       [(key) (dispatch-key state ev)]
       [(mouse) (dispatch-mouse state ev)]
       [(paste) (dispatch-paste state ev)]
       [(resize) (dispatch-resize state ev)]
       [(quit) (values (struct-copy app-state state [quit? #t]) '())]
       [(internal)
        (case (internal-event-kind ev)
          [(quit) (values (struct-copy app-state state [quit? #t]) '())]
          [else (values state '())])]
       [else (values state '())])]))
