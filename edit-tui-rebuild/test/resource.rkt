#lang racket

;;; edit-tui-rebuild/test/resource.rkt —— 打开 / 关闭文件 + document 类型携带命令
;;;
;;; 运行：racket edit-tui-rebuild/test/resource.rkt

(require rackunit
         racket/file
         racket/async-channel
         "../../edit-tui/command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/keymap.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../effects/engine.rkt"
         "../env/doc-type.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../bootstrap/commands.rkt"
         "../bootstrap/defaults.rkt"
         "../dispatch/context.rkt"
         "../runtime/run.rkt")

;;; ════════════════ 文件 / document 类型 ════════════════

(define tmp (make-temporary-file "rebuild-open-~a.rkt"))
(display-to-file "file text\n" tmp #:exists 'truncate)
(define path (path->string tmp))

(define rkt-keys (keys [(key 'z) 'note-z]))
(define rkt-type
  (make-doc-type 'rkt
                 #:extensions '("rkt")
                 #:mode 'text
                 #:keymaps (list rkt-keys)))

(define env
  (environment-merge
   default-env
   (make-environment
    #:doc-types (hash 'rkt rkt-type)
    #:commands (hash 'note-z
                     (cmd (λ (ctx)
                            (transition-pure
                             (state-chrome* (ctx-state ctx)
                                            (λ (c) (chrome-set-message c "z!"))))))))))

;;; ════════════════ 初始资源 ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define rid (region-id 1))
(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt" "initial\n"))
(void (engine-create-view! engine vid did))

(define ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did (make-doc-meta "main.rkt"))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws rid
                                   (region rid (list (view-member vid)) vid 'editor))])
    (struct-copy workspace ws [layout (make-leaf rid)])))
(define s0
  (state-set-focus (make-state #:workspace ws
                               #:ids (make-id-counter 2 2 2 1))
                   vid))

(define inbox (make-async-channel))
(define (feed s . evs)
  (transition-state (process-events env engine inbox s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (ev) (make-engine-view engine))

;;; ════════════════ C-x C-f 打开文件 ════════════════

(define s1 (feed s0 (ctrl 'x)))
(define s2 (feed s1 (ctrl 'f)))
(check-not-false (input-prompt-session (state-input s2)))
(check-equal? (prompt-handler (input-prompt-session (state-input s2))) 'open-file)
(check-equal? (prompt-label (input-prompt-session (state-input s2))) "open file: ")

;; 输入路径
(define s3
  (for/fold ([s s2]) ([c (in-string path)])
    (feed s (plain c))))
(check-equal? (prompt-text (input-prompt-session (state-input s3))) path)

;; Enter -> read-file -> open-doc -> mount
(define s4 (feed s3 (app:key-event (key 'enter))))
(check-equal? (hash-count (workspace-docs (state-workspace s4))) 2)
(check-equal? (hash-count (workspace-views (state-workspace s4))) 2)
(check-equal? (state-focus s4) (view-id 2))
(check-equal? (engine-view-doc-text (ev) (doc-id 2)) "file text\n")

;; 打开的 document 携带 doc-type 的 mode + keymaps
(define dm (workspace-doc (state-workspace s4) (doc-id 2)))
(check-equal? (doc-meta-path dm) path)
(check-equal? (doc-meta-mode dm) 'text)
(check-equal? (length (doc-meta-keymap-layers dm)) 1)
(check-equal? (doc-meta-keymap-layers dm) (list rkt-keys))

;; per-doc keymap 立即生效：z -> note-z
(define s5 (feed s4 (plain 'z)))
(check-equal? (chrome-message (state-chrome s5)) "z!")

;;; ════════════════ C-x C-k 关闭文件 ════════════════

(define s6 (feed s5 (ctrl 'x)))
(define s7 (feed s6 (ctrl 'k)))
(check-equal? (hash-count (workspace-docs (state-workspace s7))) 1)
(check-equal? (hash-count (workspace-views (state-workspace s7))) 1)
(check-equal? (state-focus s7) vid)
(check-false (workspace-doc (state-workspace s7) (doc-id 2)))
(check-false (engine-view-doc-text (ev) (doc-id 2)))
(check-equal? (engine-view-doc-text (ev) did) "initial\n")

(delete-file tmp)

(displayln "edit-tui-rebuild resource: ok")
