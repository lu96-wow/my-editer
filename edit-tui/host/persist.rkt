#lang racket

;;; edit-tui/host/persist.rkt —— 最小会话缓存的 host 入口
;;;
;;; 默认路径：<workspace-root>/.editdata/session.rktd
;;; 只保存 / 恢复 layout、focus、resources、user buffer 文本与 view 状态。
;;; 失败不阻塞启动；读不到 session 就按空会话启动。

(require "../persist/io.rkt"
         "../persist/minimal.rkt"
         "../editor/host-api.rkt")

(provide load-editor-session!
         save-editor-session!
         (all-from-out "../persist/io.rkt"))

(define (schema-ok? data)
  (and (list? data)
       (equal? (let ([p (assq 'schema data)]) (and p (cdr p)))
               session-schema)))

(define (read-valid-session file)
  (define data (read-session-data file))
  (and (schema-ok? data) data))

(define (read-session dir)
  (define file (session-file-path dir))
  (define bak (session-backup-path dir))
  (or (read-valid-session file)
      (read-valid-session bak)))

;; 读失败 / schema 不匹配 -> 原 state。restore 内部会做结构校验与 fallback。
(define (load-editor-session! ed state
                              #:workspace-root [root (state-workspace-root state)]
                              #:session-dir [dir (default-session-dir root)])
  (define data (with-handlers ([exn:fail? (λ (_e) #f)])
                 (read-session dir)))
  (cond
    [(not data) state]
    [else
     (with-handlers ([exn:fail?
                      (λ (e)
                        (eprintf "edit: session restore failed: ~a\n"
                                (exn-message e))
                        state)])
       (restore-session! ed state data))]))

(define (save-editor-session! ed state
                              #:workspace-root [root (state-workspace-root state)]
                              #:session-dir [dir (default-session-dir root)])
  (with-handlers ([exn:fail?
                   (λ (e)
                     (eprintf "edit: session save failed: ~a\n"
                             (exn-message e))
                     #f)])
    (define data (snapshot-session ed state #:workspace-root root))
    (write-session-data! dir data)
    #t))
