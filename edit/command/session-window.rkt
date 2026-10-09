#lang racket

;;; edit/command/session-window.rkt —— 状态窗口（机制）+ 输入行 + 命令处理链 + refresh
;;;
;;; 纯查询（session-panel / -panel-vid / -vid-keys / -dock-vid? / -add-panel）在 session-value。
;;; 这里只有需要内核 / 轮廓的机制：panel-dids、同位置互换、刷新、输入行、handler 链。

(require racket/string
         "session-value.rkt"
         "session-core.rkt"
         "session-focus.rkt"
         "../core/focus.rkt"
         "../core/layout.rkt"
         "../core/area.rkt")

(provide
 session-panel-dids session-panel-swap
 session-add-handler
 session-refresh
 session-bottom-select session-log! session-log-open session-log-close session-log-toggle
 session-prompt-open session-prompt-submit session-prompt-cancel)

;;; ---------- 状态窗口 ----------

(define (session-panel-dids s)
  (for/list ([p (in-list (session-panels s))])
    (session-view-did s (panel-vid p))))

;; 同组（同位置）窗口互换：Tab。底部组（'bottom）由底部选择机制管，不参与 Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define curp (and cur (session-panel s cur)))
  (define (usable? g) (and g (not (eq? g 'bottom))))
  (define group
    (cond [(and curp (usable? (panel-group curp))) (panel-group curp)]
          [else (for/first ([p (in-list (session-panels s))] #:when (usable? (panel-group p)))
                  (panel-group p))]))
  (cond
    [(not group) s]
    [else
     (define members (for/list ([p (in-list (session-panels s))]
                               #:when (eq? group (panel-group p))) p))
     (define idx (for/first ([p (in-list members)] [i (in-naturals)]
                             #:when (eqv? (panel-vid p) cur)) i))
     (define chosen (list-ref members (if idx (modulo (add1 idx) (length members)) 0)))
     (define cvid (panel-vid chosen))
     (define s1 (for/fold ([s s]) ([p (in-list members)])
                  (session-set-visible s (panel-vid p) (eqv? (panel-vid p) cvid))))
     (session-set-focus s1 (focus-set (session-focus s1) cvid))]))

;;; ---------- 命令处理链 ----------

(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))

;;; ---------- 刷新状态窗口 ----------

(define (session-refresh s)
  (for ([p (in-list (session-panels s))])
    (define f (panel-refresh p))
    (when f
      (define doc (f s))
      (when doc (session-ed-assign! s (panel-vid p) doc))))
  s)

;;; ---------- 底部区（status / input / log 互斥，高度按 rows 适配） ----------

;; 把包含 vid 的底部区域高度调到 rows 行（切换底部文档时调用一次）。
(define (session-fit-rows! s vid rows)
  (define pl (for/first ([p (in-list (session-views s))] #:when (eqv? vid (placed-vid p))) p))
  (cond
    [(not pl) s]
    [else
     (define delta (- rows (placed-h pl)))
     (cond
       [(zero? delta) s]
       [else
        (struct-copy session s
          [layout (layout-resize (session-layout s) vid 'height delta
                                 (area 0 0 (session-width s) (session-height s)))])])]))

;; 底部组（group='bottom'）互斥选择：只显示 id，并把高度适配到它的 rows。
(define (session-bottom-select s id)
  (define members (for/list ([p (in-list (session-panels s))]
                             #:when (eq? 'bottom (panel-group p))) p))
  (define s1 (for/fold ([s s]) ([p (in-list members)])
               (session-set-visible s (panel-vid p) (eq? id (panel-id p)))))
  (define target (for/first ([p (in-list members)] #:when (eq? id (panel-id p))) p))
  (cond
    [(not target) s1]
    [else (session-fit-rows! s1 (panel-vid target) (panel-rows target))]))

;; 切到 id 并把焦点 push 上去（Esc 时 restore）。
(define (session-bottom-pop s id)
  (define s1 (session-bottom-select s id))
  (define vid (session-panel-vid s1 id))
  (if vid (session-set-focus s1 (focus-push (session-focus s1) vid)) s1))

;; 刷新后把 log 光标移到最后一行（自动滚到底）。
(define (session-log-goto-end! s)
  (define vid (session-panel-vid s 'log))
  (cond
    [(not vid) s]
    [else
     (session-refresh s)                    ; 先让 log 文档反映新行
     (define n (length (session-log s)))
     (if (zero? n) s (session-ed-set-point! s vid (sub1 n) 0))]))

;; 主动打开 log（切底部 + 焦点 push + 滚到底）。
(define (session-log-open s)
  (session-log-goto-end! (session-bottom-pop s 'log)))

;; 追加一条日志（多行消息拆成多行；无 prompt → 弹 log；有 prompt → 只追加）。
(define (session-log! s text)
  (define lines (string-split (format "~a" text) "\n"))
  (define s1 (struct-copy session s [log (append (session-log s) lines)]))
  (cond
    [(session-prompt s1) s1]
    [else (session-log-open s1)]))

;; 关闭 log（Esc）：切回 status 并还原焦点。
(define (session-log-close s)
  (define s1 (session-bottom-select s 'status))
  (session-set-focus s1 (focus-restore (session-focus s1))))

;; 开关 log：显示中 → 关；否则 → 开。
(define (session-log-toggle s)
  (define vid (session-panel-vid s 'log))
  (if (and vid (session-visible? s vid))
      (session-log-close s)
      (session-log-open s)))

;;; ---------- 输入行 ----------

(define (prompt-document label)
  (panel-doc (list (list label #f))))

(define (session-prompt-open s vid label on-submit)
  (define s1 (session-ed-assign! s vid (prompt-document label)))
  (define s2 (session-ed-set-point! s1 vid 0 (string-length label)))
  (define s3 (session-bottom-select s2 'input))
  (define s4 (session-set-focus s3 (focus-push (session-focus s3) vid)))
  (struct-copy session s4 [prompt (prompt vid label on-submit)]))

(define (session-prompt-close s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define s1 (session-bottom-select s 'status))
     (define s2 (session-set-focus s1 (focus-restore (session-focus s1))))
     (struct-copy session s2 [prompt #f])]))

;; Enter：取 label 之后的文本 → 关输入行 → 回调。
(define (session-prompt-submit s)
  (define p (session-prompt s))
  (cond
    [(not p) s]
    [else
     (define full (session-view-string s (prompt-vid p)))
     (define label (prompt-label p))
     (define text (substring full (min (string-length label) (string-length full))
                             (string-length full)))
     ((prompt-on-submit p) (session-prompt-close s) text)]))

(define (session-prompt-cancel s) (session-prompt-close s))
