#lang racket

;;; edit/core/test/tui-input-test.rkt —— 事件解码：前缀激活时字符要解成命名键
;;;
;;;   raco test edit/core/test/tui-input-test.rkt
;;;
;;; 复现并锁住一个 bug：前缀（C-p / C-s …）激活时，后端若把普通字符解成文本通道，
;;; `resolve` 在前缀键表里查不到 → 取消前缀。所以 C-p d / C-s - 之类“字符键前缀”
;;; 必须让 event->binding 走 chars-as-keys? #t。

(require rackunit
         tui
         "../backend/tui.rkt"
         "../command/dispatch.rkt"
         "../command/binding.rkt"
         "../command/key.rkt"
         "../command/command.rkt"
         "../command/keys.rkt"
         "../keymap.rkt"
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/focus.rkt"
         "../focus.rkt")

(define no-mods* (mods #f #f #f))
(define ctrl (mods #t #f #f))

;; 1. 解码开关本身：无前缀 → 文本通道；有前缀 → 命名键
(check-equal? (event->binding (key-event #\d no-mods*) #f) text-binding)
(check-equal? (event->binding (key-event #\d no-mods*) #t) (key 'd))

;; 2. event->input 把开关透传（后端主循环据此判断）
(check-equal? (input-binding (event->input (key-event #\d no-mods*) #t)) (key 'd))
(check-equal? (input-binding (event->input (key-event #\p ctrl) #f)) (key 'p 'ctrl))

;; 3. 会话语义：C-p 进前缀后，
;;    · 走文本通道（旧行为）→ 前缀被取消，拿不到任何命令；
;;    · 走命名键（修复后）→ C-p d 解析成 cmd-docs-show。
(define s (session-blank 80 24 (list base-keys)))
(define-values (s1 did vid) (session-add-document s "x" 40 10 #:name "*t*"))
(define s2 (session-set-focus s1 (focus-set (session-focus s1) vid)))
(define s3 (dispatch s2 (event->input (key-event #\p ctrl))))
(check-true (prefix? (session-prefix s3)))

(check-true (cmd-prefix-cancel?
             (resolve s3 (event->input (key-event #\d no-mods*) #f))))
(check-true (cmd-docs-show?
             (resolve s3 (event->input (key-event #\d no-mods*)
                                       (and (session-prefix s3) #t)))))
