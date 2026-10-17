#lang racket

;;; edit-tui-rebuild/test/save.rkt —— 共享 status/input 槽 + y/n/yall/nall 保存确认
;;;
;;; 运行：racket edit-tui-rebuild/test/save.rkt

(require rackunit
         racket/file
         racket/async-channel
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
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
         (except-in "../bootstrap/chrome.rkt" input-show)
         "../input.rkt"
         "../projection/render.rkt"
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
  (check-true (input-active? s2))
  (check-equal? (input-value s2 (make-engine-view engine)) "")
  ;; 回归：prompt 必须真的画出来（不能被 viewport left-column 滚走）
  (define-values (_dbg-ps _dbg-cs dbg-pls) (project-frame s2 engine))
  (engine-sync-views! engine dbg-pls)
  (define-values (_dbg-cache dbg-bytes)
    (render-frame s2 engine #f #:status-parts #f))
  (check-true (string-contains? (bytes->string/utf-8 dbg-bytes) "y/n/yall/nall"))
  (define s3a (feed engine s2 (plain #\y)))
  (check-equal? (input-value s3a (make-engine-view engine)) "y")
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-equal? (region-active (workspace-region (state-workspace s3) crid))
                (chrome-status-view s3))
  (check-true (runtime-quit? (state-runtime s3)))
  (check-true (file-exists? path-y))
  (check-equal? (file->string path-y) "xhello\n")
  (check-false (state-confirm s3)))
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


;;; ════════════════ 输入占用：新 input 替换旧 input ════════════════

(define path-replace (path->string (make-temporary-file "rebuild-replace-~a.txt")))
(let-values ([(engine s0 vid crid) (make-case path-replace)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))          ; save-confirm
  (check-not-false (state-confirm s2))
  (define s3 (feed engine s2 (ctrl 'x)))
  (define s4 (feed engine s3 (ctrl 'f)))          ; 新 input：open-file
  (check-false (state-confirm s4))
  (check-true (input-active? s4))
  (check-equal? (input-value s4 (make-engine-view engine)) "")
  (check-true (string-prefix? (engine-view-view-text (make-engine-view engine) (chrome-input-view s4))
                              "Open file: "))
  (check-equal? (region-active (workspace-region (state-workspace s4) crid))
                (chrome-input-view s4))
  ;; 输入态是模态的：鼠标 / 焦点移动命令不改变焦点
  (define s4m (feed engine s4 (app:mouse-event (mouse 'press 'left) 1 1)))
  (check-equal? (state-focus s4m) (chrome-input-view s4m))
  (define s4k (feed engine s4m (app:key-event (key 'left 'alt))))
  (check-equal? (state-focus s4k) (chrome-input-view s4k))
  (check-true (input-active? s4k))
  ;; Esc 关掉 input，回到 status
  (define s5 (feed engine s4k (app:key-event (key 'escape))))
  (check-false (input-active? s5)))
(when (file-exists? path-replace) (delete-file path-replace))


;;; ════════════════ C-x C-s / save-as ════════════════

;; 已有 path：直接保存，不退出
(define path-cs (path->string (make-temporary-file "rebuild-cs-~a.txt")))
(when (file-exists? path-cs) (delete-file path-cs))
(let-values ([(engine s0 vid crid) (make-case path-cs)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'x)))
  (define s3 (feed engine s2 (ctrl 's)))
  (check-equal? (file->string path-cs) "xhello\n")
  (check-false (runtime-quit? (state-runtime s3))))
(delete-file path-cs)

;; 无 path：C-x C-s 进入 Save as 输入
(define path-sa (path->string (make-temporary-file "rebuild-sa-~a.txt")))
(when (file-exists? path-sa) (delete-file path-sa))
(let-values ([(engine s0 vid crid) (make-case #f)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'x)))
  (define s3 (feed engine s2 (ctrl 's)))
  (check-true (input-active? s3))
  (check-true (string-prefix? (engine-view-view-text (make-engine-view engine) (chrome-input-view s3))
                              "Save as: "))
  (define s4 (for/fold ([s s3]) ([c (in-string path-sa)]) (feed engine s (plain c))))
  (define s5 (feed engine s4 (app:key-event (key 'enter))))
  (check-false (input-active? s5))
  (check-equal? (file->string path-sa) "xhello\n")
  (check-equal? (doc-meta-path (workspace-doc (state-workspace s5) (doc-id 1))) path-sa))
(delete-file path-sa)

;; 无 path 的 dirty doc：save-confirm 的 y 进入 Save as，然后继续 finish
(define path-cf (path->string (make-temporary-file "rebuild-cf-~a.txt")))
(when (file-exists? path-cf) (delete-file path-cf))
(let-values ([(engine s0 vid crid) (make-case #f)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\y)))
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-true (input-active? s3))
  (check-true (string-prefix? (engine-view-view-text (make-engine-view engine) (chrome-input-view s3))
                              "Save as: "))
  (define s4 (for/fold ([s s3]) ([c (in-string path-cf)]) (feed engine s (plain c))))
  (define s5 (feed engine s4 (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s5)))
  (check-equal? (file->string path-cf) "xhello\n"))
(delete-file path-cf)


;;; ════════════════ 保存失败 / 无 path 的 yall：回到确认 prompt ════════════════

;; 保存失败：y 之后重新显示当前确认 prompt，而不是停在无输入状态
(let-values ([(engine s0 vid crid) (make-case "/nonexistent-dir-rebuild/x.txt")])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\y)))
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-true (input-active? s3))
  (check-not-false (state-confirm s3))
  (check-true (string-prefix? (engine-view-view-text (make-engine-view engine) (chrome-input-view s3))
                              "Save "))
  (define s4a (feed engine s3 (plain #\n)))
  (define s4 (feed engine s4a (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s4))))

;; 无 path + yall：停在当前项，提示用 y 走 Save as
(let-values ([(engine s0 vid crid) (make-case #f)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\y)))
  (define s3b (feed engine s3a (plain #\a)))
  (define s3c (feed engine s3b (plain #\l)))
  (define s3d (feed engine s3c (plain #\l)))
  (define s3 (feed engine s3d (app:key-event (key 'enter))))
  (check-true (input-active? s3))
  (check-not-false (state-confirm s3))
  (define s4a (feed engine s3 (plain #\n)))
  (define s4 (feed engine s4a (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s4))))


;; 非法答案：重新显示确认 prompt
(let-values ([(engine s0 vid crid) (make-case #f)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (define s3a (feed engine s2 (plain #\z)))
  (define s3 (feed engine s3a (app:key-event (key 'enter))))
  (check-true (input-active? s3))
  (check-not-false (state-confirm s3))
  (define s4a (feed engine s3 (plain #\n)))
  (define s4 (feed engine s4a (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s4))))


;;; ════════════════ C-q while save-confirm active：替换旧 input 但保留新 confirm ════════════════

(let-values ([(engine s0 vid crid) (make-case #f)])
  (define s1 (feed engine s0 (plain #\x)))
  (define s2 (feed engine s1 (ctrl 'q)))
  (check-not-false (state-confirm s2))
  (define s3 (feed engine s2 (ctrl 'q)))
  (check-not-false (state-confirm s3))
  (check-true (input-active? s3))
  (define s4a (feed engine s3 (plain #\n)))
  (define s4b (feed engine s4a (plain #\a)))
  (define s4c (feed engine s4b (plain #\l)))
  (define s4d (feed engine s4c (plain #\l)))
  (define s4 (feed engine s4d (app:key-event (key 'enter))))
  (check-true (runtime-quit? (state-runtime s4))))

(displayln "edit-tui-rebuild save: ok")
