#lang racket

;;; edit-rebuild/core/session/bottom.rkt —— 区域互斥选择 + 尺寸适配 + 日志通道（通用）
;;;
;;; 局部问题：按面声明的 region 互斥选中一个，并沿其 axis/size 适配尺寸。
;;; 本模块**不认识任何具体面板 id**：谁在哪个 region 由面自己声明。
;;;
;;; 日志通道：session-log! 只追加 + 发 'log-appended 通知；「把日志弹出来」是
;;; 日志面板插件的事（它订阅该通知）。

(require racket/string
         "session.rkt"
         "adapter.rkt"
         "panel.rkt"
         "focus.rkt"
         "hook.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt"
         "../ids.rkt"
         "../focus.rkt")

(provide session-region-select session-fit-panel! session-bottom-pop session-log!)

;; 把面沿其 axis 调到 size（'flex 跳过，由骨架决定）。
(define (session-fit-panel! s sf)
  (define size (dock-size (surface-placement sf)))
  (cond
    [(eq? size 'flex) s]
    [else
     (define vid (surface-vid sf))
     (define axis (dock-axis (surface-placement sf)))
     (define region (dock-region (surface-placement sf)))
     (define pl (for/first ([pl (in-list (session-views s))] #:when (eqv? vid (placed-vid pl))) pl))
     (define extent (and pl (if (eq? axis 'height) (placed-h pl) (placed-w pl))))
     (define delta (and extent (- size extent)))
     (if (or (not delta) (zero? delta))
         s
         (session-set-frame
          s
          (layout-resize-slot (session-frame s) region axis delta
                              (area 0 0 (session-width s) (session-height s)))) )]))

;; region 互斥选择：只显示 id，并把尺寸适配到它的声明大小。
(define (session-region-select s region id)
  (define members
    (for/list ([sf (in-list (session-surfaces s))]
               #:when (and (surface-dock? sf)
                           (eq? region (dock-region (surface-placement sf))))) sf))
  (define s1 (for/fold ([s s]) ([sf (in-list members)])
               (session-set-visible s (surface-vid sf) (eq? id (surface-id sf)))))
  (define target (for/first ([sf (in-list members)] #:when (eq? id (surface-id sf))) sf))
  (if target (session-fit-panel! s1 target) s1))

;; 切到某 region 的 id 并把焦点 push 上去（Esc 时 restore）。
(define (session-bottom-pop s id)
  (define s1 (session-region-select s slot-bottom id))
  (define vid (session-panel-vid s1 id))
  (if vid (session-set-focus s1 (focus-push (session-focus s1) vid)) s1))

;; 追加一条日志（多行消息拆成多行），并发 'log-appended 通知。
(define (session-log! s text)
  (define lines (string-split (format "~a" text) "\n"))
  (session-run-hooks (session-log-add s lines) 'log-appended (list lines)))
