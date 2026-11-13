#lang racket

;;; edit-tui/app/actions.rkt —— action 解释
;;;
;;; action 是跨层 / 跨 owner 的纯数据请求；这里把它们翻译成 host 的
;;; open / close / prompt / docs 流程。插件不直接调用这些函数。

(require "../editor/host-api.rkt"
         "../host/open.rkt"
         "../host/close.rkt"
         "../host/docs.rkt"
         "../host/filetree-io.rkt"
         "../host/bilingual.rkt"
         "../plugins/bilingual/action.rkt")

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
      [(bilingual-open-action? a)
       (define-values (s* more)
         (bilingual-open-pair! ed s
                               (bilingual-open-action-source-doc-id a)
                               (bilingual-open-action-translator-id a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(bilingual-close-action? a)
       (define-values (s* more)
         (bilingual-close-pair! ed s
                                (bilingual-close-action-source-doc-id a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(bilingual-focus-action? a)
       (define-values (s* more)
         (bilingual-focus-mirror! ed s
                                  (bilingual-focus-action-mirror-view-id a)))
       (if (null? more) s* (run-actions ed s* more))]
      [(bilingual-replace-source-action? a)
       (define-values (s* more)
         (bilingual-replace-source-lines! ed s
                                          (bilingual-replace-source-action-source-doc-id a)
                                          (bilingual-replace-source-action-start-line a)
                                          (bilingual-replace-source-action-end-line a)
                                          (bilingual-replace-source-action-lines a)))
       (if (null? more) s* (run-actions ed s* more))]
      [else s])))
