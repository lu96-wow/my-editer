#lang racket

;;; edit-tui/test/cancel.rkt —— global cancel-current
;;;
;;; 覆盖：
;;;   1. placement 等待中 + C-g -> 清 placement；
;;;   2. 没有交互 + C-g -> nothing to cancel；
;;;   3. input 占用 + C-g -> input-cancel（input mode 优先接键）；
;;;   4. C-x C-g 仍然可用。

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../base/effect.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../model/interaction.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../env/environment.rkt"
         "../dispatch/context.rkt"
         (except-in "../chrome/slot.rkt" input-show)
         "../chrome/input.rkt"
         "../bootstrap/defaults.rkt"
         "../bootstrap/commands/placement.rkt"
         "../runtime/run.rkt")

(define inbox (make-async-channel))
(define engine (make-engine))

(define (feed env s . evs)
  (transition-state (process-events env engine inbox s evs)))

(define (ctrl c) (app:key-event (key c 'ctrl)))
(define (plain c) (app:key-event (key c)))
(define (esc) (app:key-event (key 'escape)))

;;; ════════════════ 1. placement ════════════════

(define vid (view-id 1))
(define ws (workspace-set-placement (workspace-empty) vid))
(define s0 (make-state #:workspace ws))
(define s1 (feed core-env s0 (ctrl 'g)))
(check-false (workspace-placement (state-workspace s1)))
(check-equal? (chrome-message (state-chrome s1)) "placement cancelled")

;; Esc 同样可以取消
(define s2 (feed core-env (make-state #:workspace ws) (esc)))
(check-false (workspace-placement (state-workspace s2)))

;;; ════════════════ 1b. interaction 栈里的 placement ════════════════

(define sp (set-placement (make-state) vid))
(check-eq? (interaction-kind (state-interaction-top sp)) 'placement)
(define sp2 (feed core-env sp (ctrl 'g)))
(check-false (workspace-placement (state-workspace sp2)))
(check-equal? (state-interactions sp2) '())

;;; ════════════════ 2. nothing to cancel ════════════════

(define s3 (feed core-env (make-state) (ctrl 'g)))
(check-equal? (chrome-message (state-chrome s3)) "nothing to cancel")

;;; ════════════════ 2b. pending 键序列 ════════════════

(define sp0 (feed core-env (make-state) (ctrl 'x)))
(check-true (pair? (input-pending (state-input sp0))))
(check-eq? (interaction-kind (state-interaction-top sp0)) 'pending)
(define sp1 (feed core-env sp0 (ctrl 'g)))
(check-false (input-pending? (state-input sp1)))
(check-equal? (state-interactions sp1) '())

;; 未绑定键清 pending，同时 pop interaction
(define pend2 (feed core-env sp0 (plain #\p)))
(check-false (input-pending? (state-input pend2)))
(check-equal? (state-interactions pend2) '())

;; Esc 同样取消 pending
(define pend3 (feed core-env sp0 (esc)))
(check-false (input-pending? (state-input pend3)))
(check-equal? (state-interactions pend3) '())

;;; ════════════════ 3. input 占用：input mode 的 C-g 优先 ════════════════

(define s4 (install-chrome! engine (make-state #:ids (make-id-counter 1 1 2 1))
                            (region-id 1)))
(define (ctx s)
  (make-ctx core-env s (app:key-event (key 'x)) #f
            (make-engine-view engine)))
(define t (input-show (ctx s4) "Cancel me: "
                      #:tag 'cancel-test
                      #:cancel (λ (s) (plugin-state-set s 'cancel-test #t))))
(define s5
  (transition-state
   (interpret-effects! engine (transition-state t) (transition-effects t))))
(check-true (input-active? s5))
(define s6 (feed core-env s5 (ctrl 'g)))
(check-true (plugin-state s6 'cancel-test #f))
(check-false (input-active? s6))

;;; ════════════════ 4. C-x C-g 仍然清 placement ════════════════

(define s7 (feed core-env (make-state #:workspace ws) (ctrl 'x) (ctrl 'g)))
(check-false (workspace-placement (state-workspace s7)))

(displayln "edit-tui cancel: ok")
