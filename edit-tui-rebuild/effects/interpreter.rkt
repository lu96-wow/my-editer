#lang racket

;;; effects/interpreter.rkt —— effect → transition 的边缘解释器（不纯）
;;; layer  : effects
;;; effect : **IO**：执行 effect —— 文件读写、文档开关、保存、退出；
;;;            引擎写通过 effects/engine.rkt

;;; 分工：
;;;   · edit / insert / select / scroll / nav / undo / redo -> engine-apply!
;;;   · set-faces（语法高亮）                                    -> core 端口写回
;;;   · replace-range（补全）                                    -> core buffer 替换
;;;   · ensure-view（布局变化后夹光标）                           -> core view-ensure!
;;;   · open-doc / close-doc / save-doc                         -> engine + State
;;;   · read-file / write-file                                  -> 文件 IO + 回调
;;;   · quit                                                    -> State.quit?
;;;
;;; 信号：解释器是唯一知道“文本真的变了”的地方，所以由它发
;;;   after-edit（doc-id）/ after-nav（view-id）/ document-opened（doc-id）。
;;; 上色本身不发 after-edit（否则 hook 自激）。
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
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "engine.rkt"
         "../../core/editor/attributes.rkt"
         "../../core/editor/ops.rkt"
         "../../core/editor/state.rkt")

;;; ════════════════ 分类 ════════════════

(define (runtime-effect? e)
  (or (spawn-effect? e) (timer-effect? e) (emit-effect? e)))

;;; ════════════════ 单个 effect ════════════════

(define (interpret-effect! engine state effect)
  (cond
    [(engine-effect? effect)
     (engine-apply! engine effect)
     ;; 文本被改 / 光标推进：把“发生了什么”记成信号，旁观者（高亮/补全/文档）自己接。
     (transition-pure
      (cond
        [(edit-write? effect)
         (state-emit state 'after-edit (list (effect-doc state effect)))]
        [(nav-effect? effect) (state-emit state 'after-nav (list (nav-effect-view effect)))]
        [else state]))]

    [(set-faces-effect? effect)
     (interpret-set-faces! engine state effect)]

    [(replace-range-effect? effect)
     (interpret-replace-range! engine state effect)]

    [(ensure-view-effect? effect)
     (engine-ensure-view! engine (ensure-view-effect-view effect))
     (transition-pure state)]

    [(open-doc-effect? effect)
     (interpret-open-doc! engine state effect)]

    [(open-view-effect? effect)
     (interpret-open-view! engine state effect)]

    [(close-view-effect? effect)
     (define vid (close-view-effect-view effect))
     (engine-remove-view! engine vid)
     (transition-pure
      (state-workspace* state (λ (ws) (workspace-remove-view ws vid))))]

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

    [(make-directory-effect? effect)
     (define ok?
       (with-handlers ([exn:fail? (λ (_) #f)])
         (make-directory* (make-directory-effect-path effect))
         #t))
     ((make-directory-effect-k effect) state ok?)]

    [(delete-file-effect? effect)
     (define ok?
       (with-handlers ([exn:fail? (λ (_) #f)])
         (delete-file (delete-file-effect-path effect))
         #t))
     ((delete-file-effect-k effect) state ok?)]

    [(quit-effect? effect) (transition-pure (state-mark-quit state))]

    [(spawn-effect? effect)
     (error 'interpret-effect! "spawn 是 Runtime effect，尚未接线")]
    [(timer-effect? effect)
     (error 'interpret-effect! "timer 是 Runtime effect，尚未接线")]
    [(emit-effect? effect)
     (error 'interpret-effect! "emit 是 Runtime effect，尚未接线")]

    [else (error 'interpret-effect! "未知 effect：~a" effect)]))

;;; ════════════════ 上色 / 替换 ════════════════

;; 整篇重设 face：先清空（避免旧色残留），再按 fills 写一次。
(define (interpret-set-faces! engine state effect)
  (define did (set-faces-effect-doc effect))
  (define b (engine-doc-buffer engine did))
  (when b
    (buffer-face-all! b #f)
    (buffer-face-batch! b (set-faces-effect-fills effect)))
  (transition-pure state))

;; 替换一个 view 的 range（补全把前缀换成候选）：算一次编辑，所以发 after-edit。
(define (interpret-replace-range! engine state effect)
  (define vid (replace-range-effect-view effect))
  (define v (engine-view-object engine vid))
  (when v
    (buffer-replace-range! (view-buffer v)
                           (replace-range-effect-range effect)
                           (replace-range-effect-text effect)))
  (transition-pure (state-emit state 'after-edit (list (effect-doc state effect)))))

;; 这次 engine 写是不是“改文本”（insert / edit / set-text / undo / redo）。
(define (edit-write? effect)
  (or (edit-effect? effect) (insert-text-effect? effect) (set-text-effect? effect)
      (undo-effect? effect) (redo-effect? effect)))

;; effect 作用在哪个 doc 上（给信号用）：view -> doc 的对应关系在 State 里。
(define (effect-doc state effect)
  (define vid (cond [(edit-effect? effect) (edit-effect-view effect)]
                    [(insert-text-effect? effect) (insert-text-effect-view effect)]
                    [(set-text-effect? effect) (set-text-effect-view effect)]
                    [(undo-effect? effect) (undo-effect-view effect)]
                    [(redo-effect? effect) (redo-effect-view effect)]
                    [(replace-range-effect? effect) (replace-range-effect-view effect)]
                    [else #f]))
  (and vid (workspace-doc-of-view (state-workspace state) vid)))

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
  ;; 打开时把“当前版本”作为保存基线：新文档从 clean 开始。
  (define version (engine-view-doc-version (make-engine-view engine) did))
  (define dm (make-doc-meta (open-doc-spec-name spec)
                            #:path (open-doc-spec-path spec)
                            #:mode (open-doc-spec-mode spec)
                            #:saved-version version
                            #:keymap-layers (open-doc-spec-keymaps spec)))
  (define ws (state-workspace s2))
  (define ws* (workspace-add-doc ws did dm))
  (define ws** (workspace-add-view ws* vid (view-meta did (hash))))
  (define s3 (state-emit (state-set-workspace s2 ws**) 'document-opened (list did)))
  (if k
      (k s3 did vid)
      (transition-pure s3)))

;;; ════════════════ open-view ════════════════

(define (interpret-open-view! engine state effect)
  (define did (open-view-effect-doc effect))
  (define k (open-view-effect-k effect))
  (unless (engine-doc-exists? engine did)
    (error 'interpret-open-view! "doc 不存在：~a" did))
  (define-values (vid s1) (state-next-id state 'view))
  (engine-create-view! engine vid did)
  (define ws (state-workspace s1))
  (define ws* (workspace-add-view ws vid (view-meta did (hash))))
  (define s2 (state-set-workspace s1 ws*))
  (if k (k s2 vid) (transition-pure s2)))

;;; ════════════════ save-doc ════════════════

(define (interpret-save-doc! engine state effect)
  (define did (save-doc-effect-doc effect))
  (define k (save-doc-effect-k effect))
  (define ws (state-workspace state))
  (define dm (workspace-doc ws did))
  (define path (and dm (doc-meta-path dm)))
  (define ev (make-engine-view engine))
  ;; 保存的是“开始写盘时的版本”；写完若当前版本变了，不能把新编辑误标成已保存。
  (define start-version (and (engine-doc-exists? engine did)
                             (engine-view-doc-version ev did)))
  (define text (and start-version (engine-view-doc-text ev did)))
  (define ok?
    (and path text
         (with-handlers ([exn:fail? (λ (_) #f)])
           (display-to-file text path #:exists 'truncate)
           #t)))
  (define same-version?
    (and ok? start-version
         (engine-version=? start-version (engine-view-doc-version ev did))))
  (define state*
    (if (and ok? same-version?)
        (state-workspace*
         state
         (λ (ws*)
           (define dm* (workspace-doc ws* did))
           (if dm*
               (workspace-add-doc ws* did
                                  (struct-copy doc-meta dm* [saved-version start-version]))
               ws*)))
        state))
  (if k (k state* ok?) (transition-pure state*)))

;;; ════════════════ 批量 ════════════════

(define (interpret-effects! engine state effects)
  (for/fold ([t (transition-pure state)]) ([e (in-list effects)])
    (transition-bind t (λ (s) (interpret-effect-tree! engine s e)))))

;; 回调可以返回带 effect 的 transition（例如 read-file -> open-doc），
;; 这里递归解释新产生的 effects。
(define (interpret-effect-tree! engine state effect)
  (define t (interpret-effect! engine state effect))
  (interpret-effects! engine (transition-state t) (transition-effects t)))
