#lang racket

;;; edit/command/session-bottom.rkt —— 底部区（status / input / log 互斥）+ log 通道
;;;
;;; 底部三面板同位置；切换时按各 panel 的 rows 自动适配高度（只在切换时）。
;;; log 是只读日志通道：session-log! 追加，无 prompt 时弹出。

(require racket/string
         "session-value.rkt"
         "session-core.rkt"
         "session-panel.rkt"
         "session-focus.rkt"
         "../core/focus.rkt"
         "../core/layout.rkt"
         "../core/area.rkt")

(provide session-bottom-select
         session-log! session-log-open session-log-close session-log-toggle)

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
