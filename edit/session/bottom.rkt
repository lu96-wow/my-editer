#lang racket

;;; edit/session/bottom.rkt —— 底部区（status / input / log 互斥）+ log 通道
;;;
;;; 区域选择是通用的：按 panel 声明的 region 互斥选中一个，并沿 panel 声明的
;;; axis/size 适配尺寸（不再写死“底部 = tb split 高度”）。
;;; log 是只读日志通道：session-log! 追加，无 prompt 时弹出。

(require racket/string
         "value.rkt"
         "core.rkt"
         "panel.rkt"
         "focus.rkt"
         "../core/ids.rkt"
         "../core/focus.rkt"
         "../core/layout.rkt"
         "../core/area.rkt")

(provide session-region-select
         session-log! session-log-open session-log-close session-log-toggle)

;; 把 panel 沿其声明的 axis 调到 size（'flex 跳过，由骨架决定）。
;; 尺寸在骨架里（该 region 的 split），所以改 frame 再重算 layout。
(define (session-fit-panel! s p)
  (define size (panel-size p))
  (cond
    [(eq? size 'flex) s]
    [else
     (define vid (panel-vid p))
     (define axis (panel-axis p))
     (define pl (for/first ([pl (in-list (session-views s))] #:when (eqv? vid (placed-vid pl))) pl))
     (define extent (and pl (if (eq? axis 'height) (placed-h pl) (placed-w pl))))
     (define delta (and extent (- size extent)))
     (if (or (not delta) (zero? delta))
         s
         (session-set-frame
          s
          (layout-resize-slot (session-frame s) (panel-region p) axis delta
                              (area 0 0 (session-width s) (session-height s)))))]))

;; region 互斥选择：只显示 id，并把尺寸适配到它的声明大小。
(define (session-region-select s region id)
  (define members (for/list ([p (in-list (session-panels s))]
                             #:when (eq? region (panel-region p))) p))
  (define s1 (for/fold ([s s]) ([p (in-list members)])
               (session-set-visible s (panel-vid p) (eq? id (panel-id p)))))
  (define target (for/first ([p (in-list members)] #:when (eq? id (panel-id p))) p))
  (if target (session-fit-panel! s1 target) s1))

;; 切到底部区的 id 并把焦点 push 上去（Esc 时 restore）。
(define (session-bottom-pop s id)
  (define s1 (session-region-select s slot-bottom id))
  (define vid (session-panel-vid s1 id))
  (if vid (session-set-focus s1 (focus-push (session-focus s1) vid)) s1))

;; 刷新后把 log 光标移到最后一行（自动滚到底）。
(define (session-log-goto-end! s)
  (define vid (session-panel-vid s panel-log))
  (cond
    [(not vid) s]
    [else
     (session-refresh s)                    ; 先让 log 文档反映新行
     (define n (length (session-log s)))
     (if (zero? n) s (session-ed-set-point! s vid (sub1 n) 0))]))

;; 主动打开 log（切底部 + 焦点 push + 滚到底）。
(define (session-log-open s)
  (session-log-goto-end! (session-bottom-pop s panel-log)))

;; 追加一条日志（多行消息拆成多行；无 prompt → 弹 log；有 prompt → 只追加）。
(define (session-log! s text)
  (define lines (string-split (format "~a" text) "\n"))
  (define s1 (struct-copy session s [log (append (session-log s) lines)]))
  (cond
    [(session-prompt s1) s1]
    [else (session-log-open s1)]))

;; 关闭 log（Esc）：切回 status 并还原焦点。
(define (session-log-close s)
  (define s1 (session-region-select s slot-bottom panel-status))
  (session-set-focus s1 (focus-restore (session-focus s1))))

;; 开关 log：显示中 → 关；否则 → 开。
(define (session-log-toggle s)
  (define vid (session-panel-vid s panel-log))
  (if (and vid (session-visible? s vid))
      (session-log-close s)
      (session-log-open s)))
