#lang racket

;;; edit-tui-rebuild/runtime/sync.rkt —— 每帧 UI panel 同步
;;;
;;; 只同步“内容来自 State 投影”的 UI panel。
;;; 编辑器的 buffer 内容由命令 / action 写，不需要这里同步。

(require "../app/state.rkt"
         "../filetree/panel.rkt"
         "../chrome/status.rkt"
         "../chrome/input.rkt")

(provide sync-ui!)

(define (sync-ui! state engine)
  (define s1 (sync-filetree! state engine))
  (define s2 (input-sync! s1 engine))
  (sync-status! s2 engine))
