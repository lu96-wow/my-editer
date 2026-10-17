#lang racket

;;; app/minibuffer.rkt —— 命令输入（minibuffer）：输入栏 + 命令回调
;;;
;;; 命令带 `#:input spec` 时，`step` 的 run-command 调 `minibuffer-enter`：
;;;   · 存输入会话（world.ext）；
;;;   · 切到输入栏并聚焦（slot-focus-input，纯）；
;;;   · 由 step 返回一个 invoke 把 prompt 写进输入 buffer（不纯留给解释器）。
;;;
;;; 输入栏键表 `minibuffer-keys`：Enter → submit（读文本、跑命令、回状态栏）、
;;; Esc → cancel（回状态栏、丢弃）。会话结束清空。
;;;
;;; 会话存 world.ext（纯、可重放）：(minibuffer command prompt)。

(require "../../core/editor.rkt"
         "../command/main.rkt"
         "world.rkt"
         "slot.rkt"
         "intent.rkt")

(provide (struct-out minibuffer)
         minibuffer-of minibuffer-enter minibuffer-clear
         minibuffer-set-prompt! minibuffer-text
         minibuffer-submit minibuffer-cancel
         minibuffer-keys)

(define mb-key 'minibuffer)

(struct minibuffer (command prompt) #:transparent)

(define (minibuffer-of w) (world-ext-ref w mb-key #f))

;;; ---------- 进入 / 结束（纯 world 变换） ----------

;; 进入输入：存会话 + 切输入栏（记住焦点、聚焦槽）。
(define (minibuffer-enter w cmd prompt)
  (slot-focus-input (world-ext-set w mb-key (minibuffer cmd prompt))))

(define (minibuffer-clear w)
  (world-ext-set w mb-key #f))

;;; ---------- prompt 写进输入 buffer（不纯；由 step 返回 invoke 调） ----------

;; 输入 buffer = prompt（只读前缀）+ 待输入文本；光标放到 prompt 末尾。
(define (minibuffer-set-prompt! v prompt)
  (define b (view-buffer v))
  (buffer-set-document! b prompt)
  (when (positive? (string-length prompt))
    (buffer-readonly-range! b (range-of (point 0 0) (point 0 (string-length prompt))) #t))
  (view-set-point! v (point 0 (string-length prompt))))

;; 当前输入值 = 输入 buffer 文本去掉 prompt 前缀。
(define (minibuffer-text w)
  (define mb (minibuffer-of w))
  (define v (slot-member w 'input))
  (cond
    [(not (and mb v)) ""]
    [else
     (define s (buffer-string (view-buffer v)))
     (define p (minibuffer-prompt mb))
     (if (and (>= (string-length s) (string-length p))
              (string=? (substring s 0 (string-length p)) p))
         (substring s (string-length p))
         s)]))

;;; ---------- 提交 / 取消（op，返回 intent） ----------

(define (->intents x)
  (cond [(list? x) x] [(intent? x) (list x)] [else '()]))

(define (minibuffer-submit ctx)
  (define w (ctx-world ctx))
  (define mb (minibuffer-of w))
  (define val (minibuffer-text w))
  (append (if mb (->intents ((command-run (minibuffer-command mb)) val)) '())
          (slot-show-status)                 ; 回状态栏 + 恢复焦点
          (list (modify minibuffer-clear))))

(define (minibuffer-cancel ctx)
  (append (slot-show-status)
          (list (modify minibuffer-clear))))

(define minibuffer-keys
  (keys
   [(key 'enter)  minibuffer-submit]
   [(key 'escape) minibuffer-cancel]))
