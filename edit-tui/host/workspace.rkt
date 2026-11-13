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

(define (doc->resource state)
  (for/hash ([r (in-list (resources-list (state-resources state)))])
    (values (resource-doc-id r) r)))

(define (active-racket-doc-ids ed resources)
  (define engine (editor-engine ed))
  (for/list ([did (in-list (engine-user-doc-ids engine))]
             #:do [(define r (hash-ref resources did #f))]
             #:when (and r (eq? (resource-mode r) 'racket)))
    did))

(define (sync-doc ws ed resources did)
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine did))
  (cond
    [(not text) (values ws #f)]
    [else
     (define r (hash-ref resources did #f))
     (define path (workspace-normalize-path (and r (resource-path r))))
     (define version (engine-doc-version engine did))
     (define entry (workspace-doc ws did))
     (cond
       ;; 同一 path / version：复用 entry，不重建 workspace。
       [(and entry
             (equal? (document-entry-path entry) path)
             (equal? (document-entry-version entry) version))
        (values ws #f)]
       [else
        (values (workspace-set-doc ws did path text #:version version)
                #t)])]))

(define (drop-stale ws active)
  (for/fold ([ws ws] [changed? #f])
            ([did (in-list (hash-keys (workspace-docs ws)))])
    (if (member did active)
        (values ws changed?)
        (values (workspace-remove-doc ws did) #t))))

;; → workspace'（仅在变化时写回 editor 实例）
(define (workspace-sync! ed state)
  (define resources (doc->resource state))
  (define active (active-racket-doc-ids ed resources))
  (define old (or (editor-workspace ed) workspace-empty))
  (define-values (ws1 changed1?)
    (for/fold ([ws old] [changed? #f]) ([did (in-list active)])
      (define-values (ws* changed*) (sync-doc ws ed resources did))
      (values ws* (or changed? changed*))))
  (define-values (ws2 changed2?) (drop-stale ws1 active))
  (define changed? (or changed1? changed2?))
  (when changed?
    (set-editor-workspace! ed ws2))
  ws2)
