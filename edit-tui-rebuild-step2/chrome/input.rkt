#lang racket

;;; input.rkt —— 通用输入栏 API
;;; layer  : chrome
;;; effect : 只发 engine effect（写 input buffer 的 prompt / 选择）；不直接改 core

;;; 输入栏是 *input* document：
;;;   · prompt 前缀是只读 buffer 文本；
;;;   · 用户输入就是前缀之后的内容；
;;;   · 提交由 environment.input-commands 匹配完整 buffer 字符串。
;;;
;;; 占用规则：后进来的 input 替换先前的 input。
;;; 替换时：
;;;   1. 如果当前 input 有 session，直接调 session.cancel；
;;;      否则回退到旧的“用当前字符串匹配 input-command”；
;;;   2. input-finish（清 session / 切回 status / pop 焦点）；
;;;   3. 显示新 prompt，并写入新的 session。
;;;
;;; session = tag + data + cancel + prompt，存在 State.input。
;;; 它只负责“谁占用了 input / 替换时清理什么”，提交仍然由 input-command 匹配
;;; 完整 buffer 字符串。

(provide input-show input-show-state input-cancel
         input-finish input-write-prompt
         input-read-text input-value input-active? input-view
         (struct-out input-command)
         make-input-command
         input-command-prefix
         input-command-regexp
         input-command-list)

(require (rename-in "slot.rkt" [input-show chrome-input-show])
         "../base/transition.rkt"
         "../env/input-command.rkt"
         "../env/environment.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../model/interaction.rkt"
         "../effects/engine.rkt"
         "../dispatch/context.rkt")

(define (input-active? state) (state-input-active? state))

;; 只读 prefix 之后的用户输入。
(define (input-value state ev)
  (define vid (input-view state))
  (define text (and vid (engine-view-view-text ev vid)))
  (cond
    [(not (and vid text)) ""]
    [else
     (define n (string-length text))
     (define start
       (let loop ([i 0])
         (cond
           [(>= i n) n]
           [(engine-view-view-readonly-at? ev vid 0 i) (loop (add1 i))]
           [else i])))
     (substring text start)]))

;; 取消当前 input：
;;   有 session -> 直接调它的 cancel（不再靠 prompt 正则认亲）；
;;   没有 session -> 回退到旧的 input-command 匹配。
(define (input-cancel ctx)
  (define state (ctx-state ctx))
  (define session (input-session-info (state-input state)))
  (cond
    [session
     (define cancel (input-session-cancel session))
     (input-finish (if cancel (cancel state) state))]
    [else
     (define text (input-read-text state (ctx-engine ctx)))
     (define hit (and text
                      (input-command-list
                       (environment-input-commands (ctx-env ctx))
                       text)))
     (define cancel (and hit (input-command-cancel (car hit))))
     (input-finish (if cancel (cancel state) state))]))

;; input 也是 interaction 栈的一项；data = tag，cancel 由 env.interactions 的 'input 提供。
(define (input-interaction tag)
  (make-interaction (or tag 'input) 'input tag))

;; 新 input：如果已有 input，先取消旧的，再替换。
;; #:tag / #:data / #:cancel 构成新 session；不传 tag 时保持旧行为（session = #f）。
(define (input-show ctx prompt
                    #:tag [tag #f]
                    #:data [data #f]
                    #:cancel [cancel #f])
  (define s0 (if (input-active? (ctx-state ctx))
                 (input-cancel ctx)
                 (ctx-state ctx)))
  (define session (and tag (make-input-session tag data cancel prompt)))
  (chrome-input-show s0 prompt
                     #:session session
                     #:interaction (input-interaction tag)))

;; 不处理替换的底层显示；用于“已经 finish 了旧 input，再显示下一项”的内部流程。
(define (input-show-state state prompt
                          #:tag [tag #f]
                          #:data [data #f]
                          #:cancel [cancel #f])
  (define session (and tag (make-input-session tag data cancel prompt)))
  (chrome-input-show state prompt
                     #:session session
                     #:interaction (input-interaction tag)))
