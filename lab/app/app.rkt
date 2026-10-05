#lang racket

(require "../../core/editor.rkt"
         "../base/input.rkt"
         "../base/command.rkt"
         "../base/dispatch.rkt"
         "../base/layout/main.rkt"
         "../ui/tree.rkt"
         "../ui/buffers.rkt"
         "../ui/slot.rkt"
         "../ui/mode.rkt"
         "state.rkt"
         "panes.rkt"
         "edit-panes.rkt"
         "paths.rkt"
         "actions.rkt"
         "commands.rkt"
         "render.rkt")

;;; lab/app/app.rkt —— 应用装配 + 事件入口（薄壳）
;;;
;;; 这里只做三件事：init 把各部件接起来；handle-input 把事件分派到鼠标 / dispatch；
;;; 事件后兜底检查模态焦点。业务动作在 actions.rkt，状态在 state.rkt。
;;;
;;; 布局：左 = 文件树 / 文档列表，右 = 当前文件，底 = state / input 共享槽位。

(provide app-init app-handle-input app-render app-prepare! app-state-refresh!)

;;; ================= 初始化 =================

(define (app-init root width height #:sidebar-width [sw default-sidebar-width])
  (define tree (file-tree root))
  (define mw (max 1 (- width sw)))
  (define ed0 (make-blank-editor))                          ; 不预开 *scratch*，开文件才有内容
  (define-values (ed1 tdid tvid)
    (editor-add-document-view ed0 (tree->document tree) sw height "*tree*"))
  (define bmodel (buffers))
  (define-values (ed2 bdid bvid)
    (editor-add-document-view ed1 (buffers->document ed1 bmodel #f #:exclude (list tdid))
                              sw height "*buffers*"))
  (define-values (ed3 stdid stvid)
    (editor-add-document-view ed2 (state->document "") mw 1 "*state*"))
  (define-values (ed4 indid invid)
    (editor-add-document-view ed3 (input->document (input "" #t)) mw 1 "*input*"))
  (define p (panes tvid bvid stvid invid))
  ;; 输入文档不挂 did 表：模态表由 mode-tables 在 dispatch 时叠上（见 app-dispatch!）。
  (define cs (command-set-add-doc
              (command-set-add-doc
               (command-set-add-doc
                (command-set (list edit-keys app-keys))
                tdid tree-keys)
               bdid bufs-keys)
              stdid readonly-keys))
  (define a (app ed4 tree p (edit-panes-empty) bmodel 'tree tvid #f cs (make-path-table)
                 width height sw #f #f #f))
  (app-bufs-refresh! a)
  a)

;;; ================= 事件入口 =================

(define (app-dispatch! a ev)
  (define m (app-mode a))
  (cond
    ;; 前缀（如 C-p）：只看它自己的表，不回落 normal。
    ;; 处理完若还是同一个前缀，就退出；若处理器又进了一个新前缀 / 开了 prompt，就留着（支持嵌套）。
    [(prefix? m)
     (command-run (prefix-tables m) (event->binding ev) ev a)
     (when (eq? (app-mode a) m) (app-prefix-end! a))]
    [else
     (dispatch-run (app-cs a) (focused-did a)
                   (mode-tables m input-edit-keys confirm-keys)
                   ev a)]))

(define (app-handle-input a ev)
  (cond
    [(or (null-event? ev) (other-event? ev)) (void)]
    [(resize-event? ev) (app-resize! a (resize-event-cols ev) (resize-event-rows ev))]
    [(mouse-event? ev) (app-handle-mouse a ev)]
    [else (app-dispatch! a ev)])
  ;; 模态：prompt 时焦点一旦离开输入视图 → 取消（前缀不改焦点，不受此影响）。
  (when (and (prompt? (app-mode a))
             (not (eqv? (app-focus a) (app-modal-vid a))))
    (app-cancel! a))
  ;; 焦点落在某个编辑窗格 → 它就是 active（打开 / 拆分 / 删除都按它来）。
  (define f (app-focus a))
  (when (and f (edit-panes-contains? (app-edit a) f))
    (set-edit-panes-active! (app-edit a) f)))

;;; ================= 鼠标 =================

;; 鼠标落点 → 视图内坐标 → 落光标。
(define (app-move-point-to-mouse a rect ev)
  (define vid (rectangle-view-id rect))
  (define-values (line col)
    (editor-view-screen-position->point (app-ed a) vid
                                        (- (mouse-row ev) (rectangle-y rect))
                                        (- (mouse-col ev) (rectangle-x rect))))
  (when line (editor-view-set-point! (app-ed a) vid (point line col))))

(define (app-handle-mouse a ev)
  (when (prefix? (app-mode a))                 ; 前缀中点击 → 先退出前缀
    (app-prefix-end! a))
  (define p (pane-at (layout-result-panes (app-layout-result a))
                     (mouse-col ev) (mouse-row ev)))
  (cond
    ;; 输入激活：点输入行 → 定位光标；其它任何**按下** → 取消输入。
    [(prompt? (app-mode a))
     (define input-vid (app-modal-vid a))
     (cond
       [(and p (eqv? (rectangle-view-id p) input-vid))
        (when (eq? (mouse-event-action ev) 'press) (app-move-point-to-mouse a p ev))]
       [(eq? (mouse-event-action ev) 'press) (app-cancel! a)]
       [else (void)])]
    ;; 正常模式：按下 / 滚轮 → 聚焦并作用；空闲状态栏不是交互区。
    [else
     (when p
       (define vid (rectangle-view-id p))
       (unless (eqv? vid (panes-state (app-panes a)))
         (set-app-focus! a vid)
         (case (mouse-event-action ev)
           [(scroll) (editor-view-scroll! (app-ed a) vid
                                          (if (eq? (mouse-event-button ev) 'up) -1 1))]
           [(press)  (app-move-point-to-mouse a p ev)]
           [else (void)])))]))
