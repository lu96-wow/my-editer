#lang racket

;;; edit-rebuild/core/session/panel.rkt —— 停靠面（dock surface）查询 / 互换
;;;
;;; 局部问题：停靠面（状态行 / 缓冲区 / 文件树 / 日志 / 输入行）的枚举与同区域互换。
;;; 面板就是 placement 为 dock 的面；区域（region）决定互斥组。

(require "session.rkt"
         "adapter.rkt"
         "focus.rkt"
         "../surface/surface.rkt"
         "../ids.rkt"
         "../focus.rkt")

(provide session-dock-surfaces session-panel-vid session-panel-dids session-panel-swap)

(define (session-dock-surfaces s)
  (for/list ([sf (in-list (session-surfaces s))] #:when (surface-dock? sf)) sf))

;; id -> vid
(define (session-panel-vid s id)
  (define sf (session-surface-ref s id))
  (and sf (surface-vid sf)))

;; 停靠面的 did（缓冲区列表排除它们）
(define (session-panel-dids s)
  (for/list ([sf (in-list (session-dock-surfaces s))])
    (session-view-did s (surface-vid sf))))

;; 同区域窗口互换（Tab）。底部区（slot-bottom）由底部选择机制管，不参与 Tab。
(define (session-panel-swap s)
  (define cur (session-focus-vid s))
  (define cur-sf (and cur (session-surface-for-vid s cur)))
  (define (usable? sf)
    (and sf (surface-dock? sf)
         (not (eq? (dock-region (surface-placement sf)) slot-bottom))))
  (define region
    (cond
      [(usable? cur-sf) (dock-region (surface-placement cur-sf))]
      [else (for/first ([sf (in-list (session-surfaces s))] #:when (usable? sf))
              (dock-region (surface-placement sf)))]))
  (cond
    [(not region) s]
    [else
     (define members
       (for/list ([sf (in-list (session-surfaces s))]
                  #:when (and (surface-dock? sf)
                              (eq? region (dock-region (surface-placement sf))))) sf))
     (define idx (for/first ([sf (in-list members)] [i (in-naturals)]
                             #:when (eqv? (surface-vid sf) cur)) i))
     (define chosen (list-ref members (if idx (modulo (add1 idx) (length members)) 0)))
     (define cvid (surface-vid chosen))
     (define s1 (for/fold ([s s]) ([sf (in-list members)])
                  (session-set-visible s (surface-vid sf) (eqv? (surface-vid sf) cvid))))
     (session-set-focus s1 (focus-set (session-focus s1) cvid))]))
