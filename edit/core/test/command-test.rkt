#lang racket

;;; edit-rebuild/core/test/command-test.rkt —— 命令 / 派发 / 上下文（headless）
;;;
;;;   raco test edit-rebuild/core/test/command-test.rkt
;;;
;;; 注意：core 的 editor 是**原地可变**的（已知状态模型问题），所以每个独立断言
;;; 用一份新的会话，避免读到被前面改动过的状态。

(require rackunit
         "../command/command.rkt"
         "../command/dispatch.rkt"
         "../command/key.rkt"
         "../command/keys.rkt"
         "../keymap.rkt"
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/focus.rkt"
         "../focus.rkt")

;; → (values session did vid)
(define (new-session)
  (define s (session-blank 80 24 (list base-keys)))
  (define-values (s1 did vid) (session-add-document s "abc" 40 10 #:name "*t*"))
  (values (session-set-focus s1 (focus-set (session-focus s1) vid)) did vid))

;; 文本通道 → cmd-insert
(let-values ([(s did vid) (new-session)])
  (define s1 (dispatch s (input text-binding "X" #f #f #f #f)))
  (check-equal? (session-view-string s1 vid) "Xabc"))

;; 导航：左移后再打字
(let-values ([(s did vid) (new-session)])
  (define s1 (dispatch s (input text-binding "X" #f #f #f #f)))
  (define s2 (dispatch s1 (input (key 'left) #f #f #f #f #f)))
  (define s3 (dispatch s2 (input text-binding "Y" #f #f #f #f)))
  (check-equal? (session-view-string s3 vid) "YXabc"))

;; 前缀：C-p 进入前缀；方向命中前缀键表后清空
(let-values ([(s did vid) (new-session)])
  (define s1 (dispatch s (input (key 'p 'ctrl) #f #f #f #f #f)))
  (check-true (prefix? (session-prefix s1)))
  (define s2 (dispatch s1 (input (key 'left) #f #f #f #f #f)))
  (check-false (session-prefix s2)))

;; 前缀取消
(let-values ([(s did vid) (new-session)])
  (define s1 (dispatch s (input (key 'p 'ctrl) #f #f #f #f #f)))
  (define s2 (dispatch s1 (input (key 'escape) #f #f #f #f #f)))
  (check-false (session-prefix s2)))

;; step 直接派发命令
(let-values ([(s did vid) (new-session)])
  (check-equal? (session-view-string (step s (cmd-insert "Z")) vid) "Zabc"))

;; Enter → cmd-insert "\n"
(let-values ([(s did vid) (new-session)])
  (check-equal? (session-view-string (dispatch s (input (key 'enter) #f #f #f #f #f)) vid) "\nabc"))

;; 未知绑定 → 返回原会话
(let-values ([(s did vid) (new-session)])
  (check-eq? (dispatch s (input (key 'f9) #f #f #f #f #f)) s))
