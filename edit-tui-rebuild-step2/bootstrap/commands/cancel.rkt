#lang racket

;;; layer  : bootstrap/commands
;;; effect : 无（只改 State / chrome message）
;;;
;;; bootstrap/commands/cancel.rkt —— 当前交互的取消入口
;;;
;;; 取消顺序：
;;;   1. input 占用 -> input-cancel（session cancel / 旧 input-command cancel）；
;;;   2. interaction 栈顶有 cancel -> 调它（placement / confirm …）；
;;;   3. 兼容：直接设置了 workspace.placement 但没 push interaction；
;;;   4. 否则 nothing to cancel。
;;;
;;; 更高优先级的 layer 仍然先接键：
;;;   input mode 的 C-g / Esc -> input-cancel；
;;;   completion popup mode 的 C-g / Esc -> close-popup。
;;; 所以 global 的 C-g / Esc 主要补上 placement / confirm / 无模态场景。
;;;
;;; pending 键序列仍由 dispatch 的前缀逻辑处理，不在 interaction 栈里。

(provide cancel-current-command)

(require "../../base/transition.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/chrome.rkt"
         "../../model/interaction.rkt"
         "../../env/environment.rkt"
         "../../env/command.rkt"
         "../../chrome/input.rkt"
         "../../dispatch/context.rkt"
         (only-in "placement.rkt" clear-placement)
         "util.rkt")

(define (cancel-current-command)
  (cmd
   (λ (ctx)
     (define s (ctx-state ctx))
     (define top (state-interaction-top s))
     (cond
       ;; input 永远优先：它可能有 session cancel / confirm 取消要跑。
       [(input-active? s)
        (transition-pure (input-cancel ctx))]
       ;; 栈顶 interaction 的 cancel 从 env.interactions 按 kind 查（placement / confirm …）
       [(and top (environment-interaction (ctx-env ctx) (interaction-kind top)))
        (let ([handler (environment-interaction (ctx-env ctx) (interaction-kind top))])
          (handler ctx (interaction-data top)))]
       ;; 兼容：直接设置了 workspace.placement、但还没 push interaction 的路径。
       [(workspace-placement (state-workspace s))
        (notice-state (clear-placement s) "placement cancelled")]
       [else
        (notice-state s "nothing to cancel")]))))
