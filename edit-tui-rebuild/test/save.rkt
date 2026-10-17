#lang racket

;;; edit-tui-rebuild/test/save.rkt —— 共享 status/input 槽 + y/n/yall/nall 保存确认
;;;
;;; 运行：racket edit-tui-rebuild/test/save.rkt

(require rackunit
         racket/file
         racket/async-channel
         "../../edit-tui/command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../model/resources.rkt"
         "../effects/engine.rkt"
         "../bootstrap/chrome.rkt"
         "../bootstrap/defaults.rkt"
         "../runtime/run.rkt")

(define (make-case path)
  (define did (doc-id 1))
  (define vid (view-id 1))
  (define erid (region-id 1))
  (define crid (region-id 2))
  (define engine (make-engine))
  (void (engine-create-doc! engine did "save-demo.txt" "hello\n"))
  (void (engine-create-view! engine vid did))
  (define baseline (engine-view-doc-version (make-engine-view engine) did))
  (define ws0 (workspace-add-doc (workspace-empty) did
                                 (make-doc-meta "save-demo.txt"
                                                #:path path
                                                #:saved-version baseline)))
  (define ws1 (workspace-add-view ws0 vid (view-meta did (hash))))
  (define ws2 (workspace-add-region ws1 erid
                                    (region erid (list (view-member vid)) vid 'editor)))
  (define s0 (make-state #:workspace ws2 #:ids (make-id-counter 2 2 3 1)))
  (define s1 (install-chrome! engine s0 crid))
  (define lay (make-split 'tb
                          (list (make-leaf erid (flex 1))
                                (make-leaf crid (fixed 1) #:borders '()))
                          (flex 1)))
  (define s2 (state-set-workspace s1
                                  (struct-copy workspace (state-workspace s1) [layout lay])))
  (define s3 (state-set-focus s2 vid))
  (values engine s3 vid crid))

(define inbox (make-async-channel))
(define (feed eng s . evs)
  (transition-state (process-events default-env eng inbox s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (key* c)  (app:key-event c))

;;; ════════════════ y：保存后 quit ════════════════

(define path-y (path->string (make-temporary-file "rebuild-save-y-~a.txt")))
(when (file-exists? path-y) (delete-file path-y))
(let-values ([(engine s0 vid crid) (make-case path-y)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (check-equal? (region-active (workspace-region (state-workspace s2) crid))
                (chrome-input-view s2))
  (check-true (string-prefix? (engine-view-view-text (make-engine-view engine) (chrome-input-view s2))
                              "Save "))
  (define s3a (feed engine s2 (plain #\y)))
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-equal? (region-active (workspace-region (state-workspace s3) crid))
                (chrome-status-view s3))
  (check-true (runtime-quit? (state-runtime s3)))
  (check-true (file-exists? path-y))
  (check-equal? (file->string path-y) "xhello\n")
  (check-false (resources-confirm (state-resources s3))))
(delete-file path-y)

;;; ════════════════ n：跳过，不写盘 ════════════════

(define path-n (path->string (make-temporary-file "rebuild-save-n-~a.txt")))
(when (file-exists? path-n) (when (file-exists? path-n) (delete-file path-n)))
(let-values ([(engine s0 vid crid) (make-case path-n)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\n)))
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s3)))
  (check-false (file-exists? path-n)))
(when (file-exists? path-n) (delete-file path-n))

;;; ════════════════ !：保存剩余全部 ════════════════

(define path-all (path->string (make-temporary-file "rebuild-save-all-~a.txt")))
(when (file-exists? path-all) (delete-file path-all))
(let-values ([(engine s0 vid crid) (make-case path-all)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\y)))
  (define s3b (feed engine s3a (plain #\a)))
  (define s3c (feed engine s3b (plain #\l)))
  (define s3d (feed engine s3c (plain #\l)))
  (define s3 (feed engine s3d (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s3)))
  (check-equal? (file->string path-all) "xhello\n"))
(delete-file path-all)

;;; ════════════════ ?：跳过剩余全部 ════════════════

(define path-none (path->string (make-temporary-file "rebuild-save-none-~a.txt")))
(when (file-exists? path-none) (when (file-exists? path-none) (delete-file path-none)))
(let-values ([(engine s0 vid crid) (make-case path-none)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\n)))
  (define s3b (feed engine s3a (plain #\a)))
  (define s3c (feed engine s3b (plain #\l)))
  (define s3d (feed engine s3c (plain #\l)))
  (define s3 (feed engine s3d (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s3)))
  (check-false (file-exists? path-none)))
(when (file-exists? path-none) (delete-file path-none))

;;; ════════════════ C-x C-k：关闭 document 也走确认 ════════════════

(define path-close (path->string (make-temporary-file "rebuild-save-close-~a.txt")))
(when (file-exists? path-close) (delete-file path-close))
(let-values ([(engine s0 vid crid) (make-case path-close)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'x)))
  (define s3 (feed engine s2 (ctrl 'k)))
  (check-equal? (region-active (workspace-region (state-workspace s3) crid))
                (chrome-input-view s3))
  (define s3a (feed engine s3 (plain #\y)))
  (define s4 (feed engine s3a (app:key-event (key 'enter))))
  (check-equal? (hash-count (workspace-docs (state-workspace s4))) 2) ; status + input
  (check-false (state-focus s4))
  (check-equal? (file->string path-close) "xhello\n"))
(delete-file path-close)


;;; ════════════════ 多个 dirty docs：! 保存剩余全部 ════════════════

(define path-a (path->string (make-temporary-file "rebuild-multi-a-~a.txt")))
(define path-b (path->string (make-temporary-file "rebuild-multi-b-~a.txt")))
(for ([p (list path-a path-b)]) (when (file-exists? p) (delete-file p)))

(define eng-m (make-engine))
(define d1 (doc-id 1)) (define d2 (doc-id 2))
(define v1 (view-id 1)) (define v2 (view-id 2))
(define er (region-id 1)) (define cr (region-id 2))
(void (engine-create-doc! eng-m d1 "a.txt" "A\n"))
(void (engine-create-view! eng-m v1 d1))
(void (engine-create-doc! eng-m d2 "b.txt" "B\n"))
(void (engine-create-view! eng-m v2 d2))
(define evm (make-engine-view eng-m))
(define wsm
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws d1 (make-doc-meta "a.txt" #:path path-a
                                                     #:saved-version (engine-view-doc-version evm d1)))]
         [ws (workspace-add-doc ws d2 (make-doc-meta "b.txt" #:path path-b
                                                     #:saved-version (engine-view-doc-version evm d2)))]
         [ws (workspace-add-view ws v1 (view-meta d1 (hash)))]
         [ws (workspace-add-view ws v2 (view-meta d2 (hash)))]
         [ws (workspace-add-region ws er (region er (list (view-member v1) (view-member v2)) v1 'editor))])
    ws))
(define sm0 (make-state #:workspace wsm #:ids (make-id-counter 3 3 2 1)))
(define sm1 (install-chrome! eng-m sm0 cr))
(define laym (make-split 'tb
                         (list (make-leaf er (flex 1))
                               (make-leaf cr (fixed 1) #:borders '()))
                         (flex 1)))
(define sm2 (state-set-workspace sm1
                                 (struct-copy workspace (state-workspace sm1) [layout laym])))
(define sm3 (state-set-focus sm2 v1))

(define sm4 (feed eng-m sm3 (plain #\x)))       ; d1 dirty
(define sm5 (state-set-focus sm4 v2))
(define sm6 (feed eng-m sm5 (plain #\y)))       ; d2 dirty
(define sm7 (feed eng-m sm6 (ctrl 'q)))
(define sm7a (feed eng-m sm7 (plain #\y)))
(define sm7b (feed eng-m sm7a (plain #\a)))
(define sm7c (feed eng-m sm7b (plain #\l)))
(define sm7d (feed eng-m sm7c (plain #\l)))
(define sm8 (feed eng-m sm7d (app:key-event (key 'enter))))
(check-true (runtime-quit? (state-runtime sm8)))
(check-true (file-exists? path-a))
(check-true (file-exists? path-b))
(check-equal? (file->string path-a) "xA\n")
(check-equal? (file->string path-b) "yB\n")
(for ([p (list path-a path-b)]) (when (file-exists? p) (delete-file p)))

(displayln "edit-tui-rebuild save: ok")
