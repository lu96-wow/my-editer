#lang racket

;;; edit-tui/test/input-session.rkt —— 输入栏会话身份
;;;
;;; 覆盖：
;;;   1. input-show #:tag/#:data/#:cancel 写进 State.input；
;;;   2. 新 input 替换旧 input 时，直接调旧 session 的 cancel（不靠 prompt 匹配）；
;;;   3. input-finish / input-cancel 清 session；
;;;   4. 没有 session 时仍回退到 input-command 的 cancel；
;;;   5. input-show-state 也能带 session。

(require rackunit
         "../base/id.rkt"
         "../base/transition.rkt"
         "../base/effect.rkt"
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../model/state.rkt"
         "../model/input.rkt"
         "../model/interaction.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../env/environment.rkt"
         "../env/input-command.rkt"
         (except-in "../chrome/slot.rkt" input-show)
         "../chrome/input.rkt"
         "../dispatch/context.rkt")

(define engine (make-engine))
(define s0 (install-chrome! engine (make-state #:ids (make-id-counter 1 1 2 1))
                            (region-id 1)))
(define (ctx s)
  (make-ctx (environment-empty) s (app:key-event (key 'x)) #f
            (make-engine-view engine)))

;; 把这些 transition 的 engine effect 也跑掉（主要是 set-input-prompt-effect）。
(define (run s t)
  (for/fold ([s (transition-state t)]) ([e (in-list (transition-effects t))])
    (transition-state (interpret-effect! engine s e))))

;;; ════════════════ 1. 写入 session ════════════════

(define cancel-a (λ (s) (plugin-state-set s 'cancel-a #t)))
(define s1
  (run s0 (input-show (ctx s0) "Tagged A: "
                      #:tag 'a #:data 1 #:cancel cancel-a)))
(define sess (input-session-info (state-input s1)))
(check-true (input-session? sess))
(check-eq? (input-session-tag sess) 'a)
(check-eq? (input-session-data sess) 1)
(check-eq? (input-session-cancel sess) cancel-a)
(check-equal? (input-session-prompt sess) "Tagged A: ")
(check-eq? (interaction-kind (state-interaction-top s1)) 'input)
(check-eq? (interaction-id (state-interaction-top s1)) 'a)

;;; ════════════════ 2. 替换：直接调旧 session 的 cancel ════════════════

(define cancel-b (λ (s) (plugin-state-set s 'cancel-b #t)))
(define s2
  (run s1 (input-show (ctx s1) "Tagged B: "
                      #:tag 'b #:data 2 #:cancel cancel-b)))
(check-true (plugin-state s2 'cancel-a #f))
(check-false (plugin-state s2 'cancel-b #f))
(check-eq? (input-session-tag (input-session-info (state-input s2))) 'b)
;; 替换旧 input 后栈里仍只有一条 input
(check-equal? (map interaction-id (state-interactions s2)) '(b))

;;; ════════════════ 3. input-cancel 清 session ════════════════

(define s3 (input-cancel (ctx s2)))
(check-true (plugin-state s3 'cancel-b #f))
(check-false (input-session-info (state-input s3)))
(check-false (input-active? s3))
(check-equal? (state-interactions s3) '())

;;; ════════════════ 4. 无 session：回退到 input-command.cancel ════════════════

(define fallback-cmd
  (make-input-command
   'fallback
   (input-command-prefix "Fallback: ")
   (λ (ctx value) (transition-pure (ctx-state ctx)))
   #:cancel (λ (s) (plugin-state-set s 'fallback-cancelled #t))))
(define env* (environment-add-input-command (environment-empty) fallback-cmd))
(define (ctx* s)
  (make-ctx env* s (app:key-event (key 'x)) #f (make-engine-view engine)))

(define s4 (run s3 (input-show (ctx* s3) "Fallback: ")))
(check-false (input-session-info (state-input s4)))
(check-eq? (interaction-id (state-interaction-top s4)) 'input)
(define s5 (input-cancel (ctx* s4)))
(check-true (plugin-state s5 'fallback-cancelled #f))
(check-equal? (state-interactions s5) '())

;;; ════════════════ 5. input-show-state 带 session ════════════════

(define s6
  (run s5 (input-show-state s5 "State: "
                            #:tag 'from-state
                            #:data 'x
                            #:cancel (λ (s) (plugin-state-set s 'cancel-state #t)))))
(check-eq? (input-session-tag (input-session-info (state-input s6))) 'from-state)
(check-eq? (interaction-id (state-interaction-top s6)) 'from-state)
;; 再替换时 cancel 生效
(define s7 (input-cancel (ctx* s6)))
(check-true (plugin-state s7 'cancel-state #f))
(check-equal? (state-interactions s7) '())

;;; ════════════════ 6. 构造校验 ════════════════

(check-exn exn:fail? (λ () (make-input-session "not-symbol" 1 #f "p")))
(check-exn exn:fail? (λ () (make-input-session 'ok 1 'not-proc "p")))
(check-exn exn:fail? (λ () (make-input-session 'ok 1 #f 'not-string)))

(displayln "edit-tui input-session: ok")
