#lang racket

;;; effects/interpreter.rkt —— effect → transition 的边缘解释器（不纯）
;;;
;;; 分工：
;;;   · edit / insert / select / scroll / nav / undo / redo -> engine-apply!
;;;   · open-doc / close-doc / save-doc                         -> engine + State
;;;   · read-file / write-file                                  -> 文件 IO + 回调
;;;   · quit                                                    -> State.quit?
;;;
;;; 暂定：
;;;   · spawn / timer / emit 是 Runtime effect，等 runtime 块接线；这里显式报错，
;;;     避免悄悄吞掉；
;;;   · 文件 IO 目前同步做（大文件后续可改成 job effect）；
;;;   · k 统一收 state 作为第一参（open / save / read / write）；
;;;     State 仍是纯的，k 只做纯变换。

(provide interpret-effect!
         interpret-effects!
         runtime-effect?)

(require racket/file
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "engine.rkt")

;;; ════════════════ 分类 ════════════════

(define (runtime-effect? e)
  (or (spawn-effect? e) (timer-effect? e) (emit-effect? e)))

;;; ════════════════ 单个 effect ════════════════

(define (interpret-effect! engine state effect)
  (cond
    [(engine-effect? effect)
     (engine-apply! engine effect)
     (transition-pure state)]

    [(open-doc-effect? effect)
     (interpret-open-doc! engine state effect)]

    [(close-doc-effect? effect)
     (engine-remove-doc! engine (close-doc-effect-doc effect))
     (transition-pure
      (state-workspace* state
                        (λ (ws) (workspace-remove-doc ws (close-doc-effect-doc effect)))))]

    [(save-doc-effect? effect)
     (interpret-save-doc! engine state effect)]

    [(read-file-effect? effect)
     (define path (read-file-effect-path effect))
     (define text
       (with-handlers ([exn:fail? (λ (_) #f)])
         (file->string path)))
     ((read-file-effect-k effect) state text)]

    [(write-file-effect? effect)
     (define ok?
       (with-handlers ([exn:fail? (λ (_) #f)])
         (display-to-file (write-file-effect-text effect)
                          (write-file-effect-path effect)
                          #:exists 'truncate)
         #t))
     ((write-file-effect-k effect) state ok?)]

    [(quit-effect? effect) (transition-pure (state-mark-quit state))]

    [(spawn-effect? effect)
     (error 'interpret-effect! "spawn 是 Runtime effect，尚未接线")]
    [(timer-effect? effect)
     (error 'interpret-effect! "timer 是 Runtime effect，尚未接线")]
    [(emit-effect? effect)
     (error 'interpret-effect! "emit 是 Runtime effect，尚未接线")]

    [else (error 'interpret-effect! "未知 effect：~a" effect)]))

;;; ════════════════ open-doc ════════════════

(define (interpret-open-doc! engine state effect)
  (define spec (open-doc-effect-spec effect))
  (define k (open-doc-effect-k effect))
  (unless (open-doc-spec? spec)
    (error 'interpret-open-doc! "open-doc spec 要是 open-doc-spec：~a" spec))
  (define-values (did s1) (state-next-id state 'doc))
  (define-values (vid s2) (state-next-id s1 'view))
  (engine-create-doc! engine did (open-doc-spec-name spec) (open-doc-spec-text spec))
  (engine-create-view! engine vid did #:line-numbers? (open-doc-spec-line-numbers? spec))
  (define dm (make-doc-meta (open-doc-spec-name spec)
                            #:path (open-doc-spec-path spec)
                            #:mode (open-doc-spec-mode spec)))
  (define ws (state-workspace s2))
  (define ws* (workspace-add-doc ws did dm))
  (define ws** (workspace-add-view ws* vid (view-meta did (hash))))
  (define s3 (state-set-workspace s2 ws**))
  (if k
      (k s3 did vid)
      (transition-pure s3)))

;;; ════════════════ save-doc ════════════════

(define (interpret-save-doc! engine state effect)
  (define did (save-doc-effect-doc effect))
  (define k (save-doc-effect-k effect))
  (define ws (state-workspace state))
  (define dm (workspace-doc ws did))
  (define path (and dm (doc-meta-path dm)))
  (define text (and (engine-doc-exists? engine did)
                    (engine-view-doc-text (make-engine-view engine) did)))
  (define ok?
    (and path text
         (with-handlers ([exn:fail? (λ (_) #f)])
           (display-to-file text path #:exists 'truncate)
           #t)))
  (define state*
    (if ok?
        (state-workspace*
         state
         (λ (ws*)
           (define dm* (workspace-doc ws* did))
           (if dm*
               (workspace-add-doc ws* did
                                  (struct-copy doc-meta dm* [saved-version text]))
               ws*)))
        state))
  (if k (k state* ok?) (transition-pure state*)))

;;; ════════════════ 批量 ════════════════

(define (interpret-effects! engine state effects)
  (for/fold ([t (transition-pure state)]) ([e (in-list effects)])
    (transition-bind t (λ (s) (interpret-effect! engine s e)))))
