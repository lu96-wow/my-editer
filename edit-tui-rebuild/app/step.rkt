#lang racket

;;; edit-tui-rebuild/app/step.rkt —— event -> (values state actions)（纯）
;;;
;;; 这里只做三件事：
;;;   1. 选命令表（overlays > 焦点 resource 的 per-doc 表 > 焦点 panel 的表）
;;;   2. 按键 / 鼠标 / 粘贴 -> 命令或 action
;;;   3. 需要改焦点、改消息时走 app/state.rkt 的状态迁移
;;;
;;; 不碰 engine、不碰 IO；action 由 runtime 解释。

(require "../base/api.rkt"
         "../command/api.rkt"
         "../config/api.rkt"
         "../focus/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../projection/api.rkt"
         "../resource/api.rkt"
         "../chrome/input.rkt"
         "../edit/api.rkt"
         "event.rkt"
         "placement.rkt"
         "state.rkt"
         "action.rkt")

(provide step)

;;; ════════════════ 命令表 ════════════════

(define (clear-pending state)
  (struct-copy app-state state [pending '()]))

;; overlay 表在最上层；下面按「焦点 resource 的 per-doc 表 / 焦点 panel 的表」二选一。
(define (command-stack-for-focus state)
  (define rid (app-state-focus-resource state))
  (define base
    (cond
      [rid (or (resource-command-stack (app-state-resources state) rid)
               command-table-stack-empty)]
      [else
       (hash-ref (app-state-panel-stacks state)
                 (app-state-focus-panel-id state)
                 command-table-stack-empty)]))
  (command-table-stack-from-tables
   (append (app-state-overlays state)
           (command-table-stack-tables base))))

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
  (let-values ([(status value) (command-table-stack-lookup (command-stack-for-focus state) seq)])
    (case status
      [(command)
       (run-command (clear-pending state) value)]
      [(prefix)
       (values (struct-copy app-state state [pending seq]) '())]
      [else
       ;; 表里没有：可打印字符 -> 自插入到焦点 editor（兜底）；有前缀则中断前缀
       (define s1 (clear-pending state))
       (define-values (s2 actions)
         (if (null? pending)
             (edit-self-insert s1 tok)
             (values #f '())))
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
           (define d (layout-seam-drag-start layout area row col #:config default-config))
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
              (define id (layout-focus-panel-at layout area default-config row col))
              (if id
                  (values (app-state-set-focus-panel state id) '())
                  (values state '()))])])])]
    [(move)
     (define d (app-state-drag state))
     (cond
       [(not d) (values state '())]
       [else
        (define-values (layout* ok?)
          (layout-seam-drag-move layout area d row col #:config default-config))
        (values (if ok? (struct-copy app-state state [layout layout*]) state)
                '())])]
    [(release)
     (values (struct-copy app-state state [drag #f]) '())]
    [else
     (define id (layout-focus-panel-at layout area default-config row col))
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

;; 入口 / 出口都维护「prompt <-> 输入栏打开」这个不变量：
;; 这样 step 单独使用（不跑 sync / render）时，Enter 也能提交。
(define (step state ev)
  (define s1 (input-reconcile state))
  (define-values (s2 actions) (step-dispatch s1 ev))
  (values (input-reconcile s2) actions))

(define (step-dispatch state ev)
  (cond
    [(and (key-event? ev) (input-active? state))
     (input-handle-key state ev)]
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
