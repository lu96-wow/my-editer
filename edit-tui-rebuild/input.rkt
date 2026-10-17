#lang racket

;;; input.rkt —— 通用输入栏 API
;;;
;;; 输入栏是 *input* document：
;;;   · prompt 前缀是只读 buffer 文本；
;;;   · 用户输入就是前缀之后的内容；
;;;   · 其他逻辑可以：
;;;       - input-show      显示 prompt / 切到输入栏
;;;       - input-active?   判断当前是否在输入态
;;;       - input-read-text 读完整 buffer（prompt + 输入）
;;;       - input-value     只读用户输入（自动跳过只读 prefix）
;;;       - input-finish    结束输入，切回 status / 恢复焦点
;;;       - input-command   + environment.input-commands 做提交匹配
;;;
;;; 这是“generic”层：打开文件、保存确认只是默认的 input-command。

(provide input-show input-finish input-write-prompt
         input-read-text input-value input-active? input-view
         (struct-out input-command)
         make-input-command
         input-command-prefix
         input-command-regexp
         input-command-list)

(require (rename-in "bootstrap/chrome.rkt" [input-show chrome-input-show])
         "env/input-command.rkt"
         "model/resources.rkt"
         "model/state.rkt"
         "model/workspace.rkt"
         "model/chrome.rkt"
         "effects/engine.rkt")

;; 新的 input 请求会取消旧的 input；旧 input 的外部 pending 状态（目前只有
;; save-confirm 队列）也一并清掉。之后由调用方用 input-show 显示新 prompt。
(define (input-show state prompt)
  (define s0
    (if (input-active? state)
        (state-resources*
         (input-finish state)
         (λ (r) (resources-set-confirm r #f)))
        state))
  (chrome-input-show s0 prompt))

(define (input-active? state)
  (define slot (chrome-slot-info (state-chrome state)))
  (and slot
       (equal? (region-active
                (workspace-region (state-workspace state)
                                  (chrome-slot-region slot)))
               (chrome-slot-input-view slot))))

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
