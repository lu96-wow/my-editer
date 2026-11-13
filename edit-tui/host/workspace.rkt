#lang racket

;;; edit-tui/host/workspace.rkt —— 把已打开 Racket 文档同步进语言 workspace
;;;
;;; workspace 是纯值，不属于 State、也不属于 engine：
;;;   · State 不存 cache；
;;;   · engine 只存 buffer / view；
;;;   · editor 实例持有 workspace，host 每帧同步一次。
;;;
;;; 同步策略：
;;;   · 只看 user doc 且 mode = 'racket；
;;;   · 以 engine 的 document version 为缓存失效键；
;;;   · 关闭 / 切到非 Racket 的文档从 workspace 删除；
;;;   · 同一版本不会重新 analysis。
;;;
;;; 这里不做 IO，也不写 buffer；只读 engine / State。

(require "../lang/racket/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/engine/read.rkt"
         "../editor/resource.rkt")

(provide workspace-sync!)

(define (active-racket-doc-ids ed state)
  (define engine (editor-engine ed))
  (for/list ([did (in-list (engine-user-doc-ids engine))]
             #:when (eq? (state-doc-mode state did) 'racket))
    did))

(define (sync-doc ws ed state did)
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine did))
  (cond
    [(not text) ws]
    [else
     (define r (state-resource-for-doc state did))
     (workspace-set-doc ws did
                        (and r (resource-path r))
                        text
                        #:version (engine-doc-version engine did))]))

(define (drop-stale ws active)
  (for/fold ([ws ws])
            ([did (in-list (hash-keys (workspace-docs ws)))])
    (if (member did active)
        ws
        (workspace-remove-doc ws did))))

;; → workspace'（同时写回 editor 实例）
(define (workspace-sync! ed state)
  (define active (active-racket-doc-ids ed state))
  (define old (or (editor-workspace ed) workspace-empty))
  (define ws1
    (for/fold ([ws old]) ([did (in-list active)])
      (sync-doc ws ed state did)))
  (define ws2 (drop-stale ws1 active))
  (set-editor-workspace! ed ws2)
  ws2)
