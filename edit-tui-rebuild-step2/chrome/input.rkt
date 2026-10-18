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
;;;   1. 用当前 input 字符串匹配 input-command；
;;;   2. 调它的 cancel 清理外部 pending 状态；
;;;   3. input-finish（切回 status / pop 焦点）；
;;;   4. 显示新 prompt。
;;;
;;; 这样 input 本身不需要 prompt 状态机；外部状态由 input-command.cancel 负责。

(provide input-show input-show-state input-cancel
         input-finish input-write-prompt
         input-read-text input-value input-active? input-view
         (struct-out input-command)
         make-input-command
         input-command-prefix
         input-command-regexp
         input-command-list)

(require (rename-in "slot.rkt" [input-show chrome-input-show])
         "../env/input-command.rkt"
         "../env/environment.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
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

;; 取消当前 input：按当前字符串找到 owner，调 cancel，再 finish。
(define (input-cancel ctx)
  (define state (ctx-state ctx))
  (define text (input-read-text state (ctx-engine ctx)))
  (define hit (and text
                   (input-command-list
                    (environment-input-commands (ctx-env ctx))
                    text)))
  (define cancel (and hit (input-command-cancel (car hit))))
  (input-finish (if cancel (cancel state) state)))

;; 新 input：如果已有 input，先取消旧的，再替换。
(define (input-show ctx prompt)
  (define s0 (if (input-active? (ctx-state ctx))
                 (input-cancel ctx)
                 (ctx-state ctx)))
  (chrome-input-show s0 prompt))

;; 不处理替换的底层显示；用于“已经 finish 了旧 input，再显示下一项”的内部流程。
(define (input-show-state state prompt)
  (chrome-input-show state prompt))
