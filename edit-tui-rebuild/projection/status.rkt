#lang racket

;;; projection/status.rkt —— 状态栏 / 输入栏文本投影（纯、可组合）
;;;
;;; 状态栏不再写死成“位置 + path + pending/message”：
;;;   · 一个段 = status-part（name + render）；
;;;   · environment.status 提供段列表；#f = 用这里默认段；
;;;   · 默认段只有 focus 行列 + 文件路径；
;;;   · full-status-parts 额外带 pending / message（默认 env 用这个）。
;;;
;;; 段 render 返回 #f / "" 会被跳过，段之间用两个空格连接。

(provide status-line
         status-position
         status-path
         status-sequence
         status-message
         default-status-parts
         full-status-parts
         status-position-part
         status-path-part
         status-sequence-part
         status-message-part
         state-line
         chrome-line
         region-line)

(require racket/string
         "../base/id.rkt"
         "../model/layout.rkt"
         "../base/status.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../../edit-tui/command/key.rkt")

;;; ════════════════ 基础投影 ════════════════

;; 焦点在 chrome（status/input）上时，状态栏报告第一个 editor view，
;; 避免移动状态栏光标导致状态栏文本自指。
(define (chrome-slot-view? state vid)
  (define slot (chrome-slot-info (state-chrome state)))
  (and slot
       (or (equal? vid (chrome-slot-status-view slot))
           (equal? vid (chrome-slot-input-view slot)))))

(define (first-editor-view state)
  (define ws (state-workspace state))
  (for/first ([rid (in-list (tree-visible-regions (workspace-layout ws)))])
    (define reg (workspace-region ws rid))
    (define active (and reg (region-active reg)))
    (and reg
         (eq? (region-role reg) 'editor)
         active
         (workspace-view ws active)
         active)))

(define (status-view state)
  (define f (state-focus state))
  (cond
    [(not f) (first-editor-view state)]
    [(chrome-slot-view? state f) (or (first-editor-view state) f)]
    [else f]))

(define (status-position state ev)
  (define vid (status-view state))
  (define line (and vid (engine-view-view-point-line ev vid)))
  (define col  (and vid (engine-view-view-point-column ev vid)))
  (and line col (cons (add1 line) (add1 col))))

(define (status-path state)
  (define ws (state-workspace state))
  (define vid (status-view state))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define dm (and did (workspace-doc ws did)))
  (and dm (doc-meta-path dm)))

(define (status-sequence state)
  (define p (input-pending (state-input state)))
  (and (pair? p) (string-join (map key->string p) " ")))

(define (status-message state)
  ;; pending 优先：有未完成键序列时，状态消息让位（与旧行为一致）。
  (define p (input-pending (state-input state)))
  (cond
    [(pair? p) #f]
    [else
     (define m (chrome-message (state-chrome state)))
     (and (positive? (string-length m)) m)]))

;;; ════════════════ 段 ════════════════

(define status-position-part
  (make-status-part 'position
                    (λ (state ev)
                      (define p (status-position state ev))
                      (and p (format "~a:~a" (car p) (cdr p))))))

(define status-path-part
  (make-status-part 'path (λ (state ev) (status-path state))))

(define status-sequence-part
  (make-status-part 'sequence (λ (state ev) (status-sequence state))))

(define status-message-part
  (make-status-part 'message (λ (state ev) (status-message state))))

;; 默认：focus 行列 + 文件路径。
(define default-status-parts
  (list status-position-part status-path-part))

;; 默认 env 用的完整状态栏：再加 pending / message。
(define full-status-parts
  (list status-position-part status-path-part
        status-sequence-part status-message-part))

;; parts #f -> default-status-parts。
(define (status-line state ev [parts #f])
  (define ps (or parts default-status-parts))
  (define pieces
    (for/list ([p (in-list ps)])
      (define s ((status-part-render p) state ev))
      (and s (positive? (string-length s)) s)))
  (string-join (filter values pieces) "  "))

;;; ════════════════ 调试 State 行 ════════════════

(define (state-line state ev)
  (define pos (status-position state ev))
  (define ws (state-workspace state))
  (define focus (state-focus state))
  (define editors
    (for/sum ([r (in-hash-values (workspace-regions ws))]
              #:when (eq? (region-role r) 'editor))
      1))
  (format "state focus=~a pos=~a docs=~a views=~a editors=~a regions=~a pending=~a msg=~a"
          (if focus (id->string focus) "-")
          (if pos (format "~a:~a" (car pos) (cdr pos)) "-")
          (hash-count (workspace-docs ws))
          (hash-count (workspace-views ws))
          editors
          (hash-count (workspace-regions ws))
          (or (status-sequence state) "-")
          (let ([m (chrome-message (state-chrome state))])
            (if (string=? m "") "-" m))))

;;; ════════════════ chrome region ════════════════

(define (chrome-line state ev key [parts #f])
  (case key
    [(status) (status-line state ev parts)]
    [(state)  (state-line state ev)]
    [else ""]))

(define (region-line state ev rid [parts #f])
  (define ws (state-workspace state))
  (define reg (workspace-region ws rid))
  (and reg
       (let ([active (region-active reg)])
         (for/first ([m (in-list (region-members reg))]
                     #:when (equal? (member-key m) active))
           (and (chrome-member? m)
                (chrome-line state ev (member-key m) parts))))))
