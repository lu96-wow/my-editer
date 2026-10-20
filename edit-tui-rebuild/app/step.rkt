#lang racket

;;; edit-tui-rebuild/app/step.rkt —— event -> (values state actions)（纯）

(require "../base/api.rkt"
         "../command/api.rkt"
         "../config/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../projection/api.rkt"
         "../resource/api.rkt"
         "../focus/api.rkt"
         "../chrome/input.rkt"
         "../edit/api.rkt"
         "event.rkt"
         "placement.rkt"
         "state.rkt"
         "action.rkt")

(provide step)

(define (notice state text)
  (struct-copy app-state state [message text]))

(define (clear-pending state)
  (struct-copy app-state state [pending '()]))

(define (focus-panel state)
  (layout-focus (app-state-layout state)))

(define (focus-view state)
  (define p (layout-panel (app-state-layout state) (focus-panel state)))
  (and p (panel-view p)))

(define (focus-resource* state)
  (define vid (focus-view state))
  (and vid (resource-of-view (app-state-resources state) vid)))

(define (command-stack state)
  (define rs (app-state-focus-resource state))
  (define base-stack
    (cond
      [rs
       (or (resource-command-stack (app-state-resources state) rs)
           command-table-stack-empty)]
      [else
       (hash-ref (app-state-panel-stacks state)
                 (focus-panel state)
                 command-table-stack-empty)]))
  (command-table-stack-from-tables
   (append (app-state-overlays state)
           (command-table-stack-tables base-stack))))

(define (run-command-value state value)
  (if (procedure? value)
      (value state)
      (values (notice state (format "not a command: ~a" value)) '())))

(define (dispatch-key state ev)
  (define tok (key-event-token ev))
  (define seq (append (app-state-pending state) (list tok)))
  (define stack (command-stack state))
  (let-values ([(status value) (command-table-stack-lookup stack seq)])
    (case status
      [(command)
       (define s1 (clear-pending state))
       (run-command-value s1 value)]
      [(prefix)
       (values (struct-copy app-state state [pending seq]) '())]
      [else
       ;; 表里没有：可打印字符 -> 自插入到焦点 editor（兜底）
       (define s1 (clear-pending state))
       (define-values (s2 actions)
         (if (null? (app-state-pending state))
             (edit-self-insert s1 tok)
             (values #f '())))
       (cond
         [s2 (values s2 actions)]
         [else
          (values (notice s1
                          (format "unbound: ~a"
                                  (string-join (map key->string seq) " ")))
                  '())])])))

(define (set-focus-panel state id)
  (define layout* (layout-set-focus (app-state-layout state) id))
  (define s1 (struct-copy app-state state [layout layout*]))
  (struct-copy app-state s1 [focus-resource (focus-resource* s1)]))

;; 点击落在 panel 内容区 -> 把该 view 的主光标设到点击处（内容区相对坐标）。
;;; 所有面板一视同仁：文件树也只是普通 buffer，光标归 view 所有。
(define (mouse-point-actions state pid row col)
  (define p (layout-panel (app-state-layout state) pid))
  (define vid (and p (panel-view p)))
  (if vid
      (list (view-action 'point vid (list row col)))
      '()))

(define (dispatch-mouse state ev)
  (define row (mouse-event-row ev))
  (define col (mouse-event-col ev))
  (define tok (mouse-event-token ev))
  (define area (app-state-area state))
  (define layout (app-state-layout state))
  (case tok
    [(press)
     (define placement-id (app-state-placement state))
     (define hit-id (layout-panel-id-at layout area row col))
     (cond
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
           ;; 先看是否点在某个 panel 的内容区（去掉边框）：
           ;; editor -> 聚焦 + 光标落点；其它 panel -> 只聚焦。
           (define-values (cid c-row c-col)
             (layout-content-hit-at layout area row col))
           (cond
             [cid
              (define s1 (set-focus-panel state cid))
              (values s1 (mouse-point-actions s1 cid c-row c-col))]
             [else
              (define id (layout-focus-panel-at layout area default-config row col))
              (if id
                  (values (set-focus-panel state id) '())
                  (values state '()))])])])]
    [(move)
     (define d (app-state-drag state))
     (cond
       [(not d) (values state '())]
       [else
        (define-values (layout* ok?)
          (layout-seam-drag-move layout area d row col #:config default-config))
        (values (if ok?
                    (struct-copy app-state state [layout layout*])
                    state)
                '())])]
    [(release)
     (values (struct-copy app-state state [drag #f]) '())]
    [else
     (define id (layout-focus-panel-at layout area default-config row col))
     (if id
         (values (set-focus-panel state id) '())
         (values state '()))]))

(define (dispatch-paste state ev)
  ;; 只有焦点在 editor 上才允许粘贴（不往 filetree / status 里灌文本）。
  ;; action 里传原始字节，engine 写 buffer 时解码。
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (notice state "paste: 焦点不是 editor") '())]
    [else
     (values state (list (view-action 'paste vid (paste-event-bytes ev))))]))

(define (dispatch-resize state ev)
  (values (struct-copy app-state state
                       [area (rect 0 0 (resize-event-cols ev) (resize-event-rows ev))])
          '()))

(define (step state ev)
  (cond
    [(and (key-event? ev) (input-active? state))
     (input-handle-key state ev)]
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
