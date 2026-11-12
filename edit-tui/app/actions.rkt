#lang racket

;;; edit-tui/app/actions.rkt —— action 解释
;;;
;;; action 是跨层 / 跨 owner 的纯数据请求；这里把它们翻译成 host 的
;;; open / close / prompt / docs 流程。插件不直接调用这些函数。

(require "../editor/host-api.rkt"
         "../host/open.rkt"
         "../host/close.rkt"
         "../host/docs.rkt"
         "../host/filetree-io.rkt")

(provide run-actions)

(define (run-actions ed state actions)
  (for/fold ([s state]) ([a (in-list actions)])
    (cond
      [(quit-action? a) (state-with-quit s #t)]
      [(flash-action? a) (state-with-flash s (flash-action-message a))]
      [(open-file-action? a)
       (define-values (s* more)
         (editor-open-file! ed s (open-file-action-path a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(close-buffer-action? a)
       (define-values (s* more) (editor-close-buffer-command ed s))
       (if (null? more) s* (run-actions ed s* more))]
      [(show-docs-action? a)
       (define-values (s* more) (editor-show-docs! ed s (show-docs-action-name a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-create-action? a)
       (define-values (s* more)
         (open-filetree-create-prompt! s
                                       (filetree-create-action-parent a)
                                       (filetree-create-action-kind a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-delete-action? a)
       (define-values (s* more)
         (open-filetree-delete-prompt! s
                                       (filetree-delete-action-path a)
                                       (filetree-delete-action-kind a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-rename-action? a)
       (define-values (s* more)
         (open-filetree-rename-prompt! s (filetree-rename-action-path a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(filetree-find-action? a)
       (define-values (s* more)
         (open-filetree-find-prompt! s (filetree-find-action-query a)))
       (if (null? more) s* (run-actions ed s* more))]
      [else s])))
