#lang racket

(require "../../../core/editor.rkt"
         "../../ui/mode.rkt"
         "../state.rkt")

;;; lab/app/actions/modal.rkt —— 输入转移动作（前缀键 / prompt）
;;;
;;; 只做「挂文档 / 聚焦 / 退出模态」，命令表选择交给 dispatch（mode-tables）。
;;; 不依赖其它动作模块：tree.rkt 等反过来用它。

(provide app-prefix-begin! app-prefix-end! app-begin! app-commit! app-answer! app-cancel!)

;; 前缀键：进入只认 tables 的瞬时状态；下一次按键后由 app 退出（见 app-dispatch!）。
(define (app-prefix-begin! a label tables)
  (app-mode-set! a (prefix-begin label tables)))

(define (app-prefix-end! a)
  (when (prefix? (app-mode a)) (app-mode-set! a #f)))

;; 发起 prompt：存下 prompt、把输入文档挂到底部槽位、聚焦。
(define (app-begin! a label editable? on-commit [on-cancel #f])
  (define p (input-begin label editable? (app-focus a) on-commit on-cancel))
  (app-mode-set! a p)
  (define vid (app-modal-vid a))
  (editor-view-assign! (app-ed a) vid (prompt-document p ""))
  (editor-view-set-point! (app-ed a) vid (point 0 (string-length label)))
  (set-app-focus! a vid))

;; 提交 / 取消都**先退出模态再调续延**（续延里可能立刻发起下一个 prompt，链式）。
(define (app-commit! a)
  (define p (app-mode a))
  (when (and (prompt? p) (prompt-editable? p))
    (define s (editor-view-string (app-ed a) (app-modal-vid a)))
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-commit p s)))

(define (app-answer! a yes?)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-answer p yes?)))

(define (app-cancel! a)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-cancel p)))
