#lang racket

;;; edit-tui/editor/ops/raw.rkt —— 裸操作（不跑扩展点）
;;;
;;; 只有 editor/ops/surface.rkt 和 editor 内部实现需要调用这里。
;;; 裸操作 = “不再触发 hook”，但仍受 core 的只读 / 选区 / 历史语义约束。
;;;
;;; 返回值统一：
;;;   #f           被拒绝
;;;   '()          成功但无文本变化
;;;   (listof change) 精确变更

(require "../../core/api.rkt"
         "../engine/user-write.rkt")

(provide raw-insert!
         raw-paste!
         raw-backspace!
         raw-delete!
         raw-kill-line!
         raw-undo!
         raw-redo!
         raw-move!
         raw-set-point!
         raw-set-selections!
         raw-scroll!
         raw-ensure!)

(define (raw-insert! engine vid text)
  (engine-apply-user-action! engine
                             (view-action 'insert vid
                                          (string->bytes/utf-8 text))))

(define (raw-paste! engine vid bytes)
  (engine-apply-user-action! engine
                             (view-action 'paste vid bytes)))

(define (raw-backspace! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'backspace vid #f)))

(define (raw-delete! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'delete vid #f)))

(define (raw-kill-line! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'kill-line vid #f)))

(define (raw-undo! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'undo vid #f)))

(define (raw-redo! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'redo vid #f)))

;; dir : 'left | 'right | 'up | 'down | 'home | 'end
(define (raw-move! engine vid dir [extend? #f])
  (engine-apply-user-action! engine
                             (view-action 'nav vid
                                          (if extend? (list dir #t) dir))))

;; 内容区相对坐标（0 基）；越界由 engine 夹到最近有效位置。
(define (raw-set-point! engine vid line col [extend? #f])
  (engine-apply-user-action! engine
                             (view-action 'point vid
                                          (list line col extend?))))

(define (raw-set-selections! engine vid sels)
  (engine-apply-user-action! engine
                             (view-action 'select vid sels)))

;; which : number | 'page-up | 'page-down
(define (raw-scroll! engine vid which)
  (engine-apply-user-action! engine
                             (view-action 'scroll vid which)))

(define (raw-ensure! engine vid)
  (engine-apply-user-action! engine
                             (view-action 'ensure vid #f)))

