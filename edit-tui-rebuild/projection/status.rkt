#lang racket

;;; projection/status.rkt —— 状态栏 / 输入栏文本投影（纯）
;;;
;;; 状态栏不再是 buffer，也不每帧写 buffer：它是一个纯函数
;;;
;;;     (status-line state engine-view) -> string
;;;
;;; 组成：焦点 view 的行列 + 焦点 document 的 path +（pending 键序列 | chrome.message）。
;;; prompt 激活时，输入区域显示 prompt.label + prompt.text。
;;;
;;; 渲染层把这里产出的字符串画到 chrome region 的内容区；不经过 core view。

(provide status-line
         status-position
         status-path
         status-sequence
         prompt-line
         state-line
         chrome-line
         region-line)

(require racket/string
         "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../../edit-tui/command/key.rkt")

;;; ---------- 状态栏 ----------

(define (status-position state ev)
  (define vid (state-focus state))
  (define line (and vid (engine-view-view-point-line ev vid)))
  (define col  (and vid (engine-view-view-point-column ev vid)))
  (and line col (cons (add1 line) (add1 col))))

(define (status-path state)
  (define ws (state-workspace state))
  (define vid (state-focus state))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define dm (and did (workspace-doc ws did)))
  (and dm (doc-meta-path dm)))

(define (status-sequence state)
  (define p (input-pending (state-input state)))
  (and (pair? p) (string-join (map key->string p) " ")))

;; 纯投影：位置 路径 (键序列 | 状态消息)，空段省略。
(define (status-line state ev)
  (define pos (status-position state ev))
  (define msg (chrome-message (state-chrome state)))
  (string-join
   (for/list ([s (in-list (list (and pos (format "~a:~a" (car pos) (cdr pos)))
                                (status-path state)
                                (or (status-sequence state) msg)))]
              #:when (and s (positive? (string-length s))))
     s)
   "  "))

;;; ---------- prompt ----------

(define (prompt-line state)
  (define p (input-prompt-session (state-input state)))
  (and p (string-append (prompt-label p) (prompt-text p))))

;;; ---------- 调试用：把 State 压成一行 ----------

;; 给 demo / 诊断用：focus / 光标 / 文档 / view / region / pending / message。
(define (state-line state ev)
  (define pos (status-position state ev))
  (define ws (state-workspace state))
  (define focus (state-focus state))
  (format "state focus=~a pos=~a docs=~a views=~a regions=~a pending=~a msg=~a"
          (if focus (id->string focus) "-")
          (if pos (format "~a:~a" (car pos) (cdr pos)) "-")
          (hash-count (workspace-docs ws))
          (hash-count (workspace-views ws))
          (hash-count (workspace-regions ws))
          (or (status-sequence state) "-")
          (let ([m (chrome-message (state-chrome state))])
            (if (string=? m "") "-" m))))

;;; ---------- chrome region ----------

;; chrome 成员键 -> 文本。未知成员 -> ""。
(define (chrome-line state ev key)
  (case key
    [(status) (status-line state ev)]
    [(state)  (state-line state ev)]
    [(input)  (or (prompt-line state) "")]
    [else ""]))

;; 某 region 当前 active member 的显示文本。
;;   view 成员 -> #f（内容由 core view 自己渲染）
;;   chrome 成员 -> 文本
(define (region-line state ev rid)
  (define ws (state-workspace state))
  (define reg (workspace-region ws rid))
  (and reg
       (let ([active (region-active reg)])
         (for/first ([m (in-list (region-members reg))]
                     #:when (equal? (member-key m) active))
           (and (chrome-member? m)
                (chrome-line state ev (member-key m)))))))
