#lang racket

;;; edit-rebuild/plugins/ui/lifecycle.rkt —— 关闭 / 退出策略（交互）
;;;
;;; 有未保存修改时先问：关文档 / 关视图 / 退出。交互用 prompt 回调链实现，不新增会话状态。
;;; 依赖本层的 session-save，不反向依赖。

(require racket/string
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/structure.rkt"
         "../../core/session/prompt.rkt"
         "../../core/session/panel.rkt"
         "../../core/command/command.rkt"
         "../../core/keymap.rkt"
         "../../core/extension/spec.rkt"
         "document.rkt")

(provide lifecycle-spec session-close-doc session-close-view-checked session-quit-confirm)

;;; ---------- 退出确认 ----------

(define (quit-answer ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [(member a '("all" "a")) 'all]
        [(member a '("nall" "none" "!")) 'nall]
        [else 'invalid]))

(define (dirty-dids s)
  (for/list ([d (in-list (session-file-dids s))] #:when (session-dirty? s d)) d))

(define (session-quit-ask s remaining)
  (cond
    [(null? remaining) (session-quit s)]
    [else
     (define did (first remaining))
     (define more (rest remaining))
     (step s (cmd-prompt-open
       (format "save ~a? (y/n/all/nall) " (session-document-name s did))
       (lambda (s ans)
         (case (quit-answer ans)
           [(yes)  (session-quit-ask (session-save s did) more)]
           [(no)   (session-quit-ask s more)]
           [(all)  (session-quit (for/fold ([s (session-save s did)]) ([d (in-list more)]) (session-save s d)))]
           [(nall) (session-quit s)]
           [else (session-quit-ask s remaining)]))))]))

(define (session-quit-confirm s)
  (define ds (dirty-dids s))
  (if (null? ds) (session-quit s) (session-quit-ask s ds)))

;;; ---------- 关闭 ----------

(define (yes-no ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [else 'invalid]))

;; 关文档：脏则问是否保存。唯一的关文档入口。
(define (session-close-doc s did)
  (cond
    [(not (session-dirty? s did)) (session-close-document s did)]
    [else
     (step s (cmd-prompt-open
       (format "save ~a? (y/n) " (session-document-name s did))
       (lambda (s ans)
         (case (yes-no ans)
           [(yes) (session-close-document (session-save s did) did)]
           [(no)  (session-close-document s did)]
           [else  (session-close-doc s did)]))))]))

(define (session-close-view-checked s vid)
  (define did (session-view-did s vid))
  (if (null? (remove vid (session-document-view-list s did)))
      (session-close-doc s did)
      (session-close-view s vid)))

;;; ---------- handler + 装配 ----------

(define (lifecycle-handler)
  (lambda (s cmd)
    (cond [(cmd-quit? cmd) (session-quit-confirm s)]
          [else #f])))

(define (lifecycle-install s)
  (session-add-handler s (lifecycle-handler)))

(define lifecycle-spec (plugin-spec 'lifecycle lifecycle-install '()))
