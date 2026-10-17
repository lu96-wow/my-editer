#lang racket

;;; layer  : bootstrap/commands
;;; effect : 只改 State（workspace.placement + region members / focus）
;;;
;;; placement = “把一个 detached view 放进某个 panel”的两步交互：
;;;   1. 某个面板（资源列表 / 文件树）设 workspace.placement = view-id；
;;;   2. 用户点目标 panel（placement scope 规则）或 C-x C-p（当前焦点）提交。
;;;
;;; 因此它是框架级交互，不属于任何插件；插件只负责发起。
;;; 目标合法性由 role.target?（区域）与 doc-meta.internal?（成员）决定。

(provide place-into
         place-commit-command
         place-at-command
         place-cancel-command
         placement-scope
         placement-keys)

(require "../../env/command.rkt"
         "../../base/id.rkt"
         "../../base/keymap.rkt"
         "../../base/transition.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/chrome.rkt"
         "../../env/environment.rkt"
         "../../env/role.rkt"
         "../../env/scope.rkt"
         "../../dispatch/context.rkt"
         "../../../edit-tui/command/mouse.rkt"
         "util.rkt")

(define (place-cancel-command)
  (cmd (λ (ctx)
         (transition-pure
          (state-workspace* (ctx-state ctx)
                            (λ (w) (workspace-set-placement w #f)))))))

;;; ════════════════ placement（把 detached view 放进某个 panel） ════════════════
;;
;; placement 是**框架级**交互，不是某个面板的命令：
;;   · 资源面板的 r、文件树面板的 Enter(open) 都只是把 workspace.placement 设成某个 view-id；
;;   · 之后鼠标点目标 panel（placement scope 规则）或 C-x C-p（当前焦点）提交；
;;   · C-x C-g / Esc 取消。
;;
;; 所以 place-into / scope / keys 住在这里，面板插件只负责“发起”。
(define (place-into ctx target)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define selected (workspace-placement ws))
  (cond
    [(not selected) (message ctx "place: no selected view")]
    [else
     (cond
       [(not (workspace-view ws selected))
        (transition-pure
         (state-chrome*
          (state-workspace* s (λ (w) (workspace-set-placement w #f)))
          (λ (c) (chrome-set-message c "place: selected view no longer exists"))))]
       [else
        (define target-reg
          (cond
            [(and target (view-id? target)) (workspace-view-region ws target)]
            [(and target (region-id? target)) (workspace-region ws target)]
            [else #f]))
        (cond
          [(not target-reg) (message ctx "place: choose a target panel")]
          [else
           (define target-region (workspace-region ws (region-key target-reg)))
           (define target-active (region-active target-region))
           (define target-active-view
             (and target-active (workspace-view ws target-active)))
           (define target-doc
             (and target-active-view (workspace-doc ws (view-meta-doc target-active-view))))
           ;; 目标合法性完全由 role.target? + doc.internal? 决定，不看具体面板名字。
           (cond
             [(or (not (role-target? (environment-role (ctx-env ctx) (region-role target-region))))
                  (and target-doc (doc-meta-internal? target-doc)))
              (message ctx "place: target is not an editor panel")]
             [else
              (define ws1
                (if (and target-active-view (not (equal? target-active selected)))
                    (workspace-detach-view ws target-active)
                    ws))
              (define ws2 (workspace-attach-view ws1 (region-key target-reg) selected))
              (define s1 (state-set-workspace s ws2))
              (define s2 (state-workspace* s1 (λ (w) (workspace-set-placement w #f))))
              (transition-pure
               (state-chrome*
                (state-set-focus s2 selected)
                (λ (c) (chrome-set-message c "view placed"))))])])])]))

(define (place-commit-command)
  (cmd (λ (ctx) (place-into ctx (state-focus (ctx-state ctx))))))

(define (place-at-command)
  (cmd (λ (ctx) (place-into ctx (ctx-subject ctx)))))

(define placement-scope
  (make-scope (λ (s) (and (workspace-placement (state-workspace s)) #t))))

(define placement-keys
  (keys [(mouse 'press 'left) 'place-at]))
