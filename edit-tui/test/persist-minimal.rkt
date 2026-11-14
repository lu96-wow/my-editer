#lang racket

;;; 最小会话缓存：layout / focus / resources / user buffer / view 状态 roundtrip。

(require rackunit
         racket/file
         (except-in racket/list range)
         racket/path
         "../core/api.rkt"
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../editor/host-api.rkt"
         "../edit.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt"
         "../host/persist.rkt")

(define root (make-temporary-directory))

(define (make-file name text)
  (define p (build-path root name))
  (display-to-file text p #:exists 'replace)
  p)

(define (panel-id-sort-key x) (format "~a" x))
(define (sorted-panel-ids l)
  (sort (layout-panel-ids l)
        (λ (a b) (string<? (panel-id-sort-key a) (panel-id-sort-key b)))))

(define (find-resource rs path)
  (for/first ([r (in-list (resources-list rs))]
              #:when (equal? (resource-path r) path))
    r))

(define a (make-file "a.rkt" "#lang racket\n(define a 1)\n"))
(define b (make-file "b.txt" "bee\n"))
(define c (make-file "c.txt" "sea\n"))
(define a-path (resource-normalize-path a))
(define b-path (resource-normalize-path b))
(define c-path (resource-normalize-path c))

(define-values (ed s0) (make-editor-app #:workspace-root root))
(define s1 (state-with-screen s0 (rect 0 0 80 24)))

;; 打开 a、插入未保存内容、移动光标。
(define-values (s2 _a2) (editor-open-file! ed s1 a))
(define va (editor-placement-view-id s2))
(define-values (s3 _a3) (editor-placement-commit ed s2))
(define-values (s4 _a4) (editor-insert! ed s3 va ";; unsaved\n"))
(define-values (s5 _a5) (editor-set-point! ed s4 va 1 2))
(define-values (s5s _a5s)
  (editor-select! ed s5 va
                  (selections-one (selection (point 1 0) (point 1 2)))))

;; 切一个 editor panel，再打开 b。
(define-values (s6 _a6) (editor-split! ed s5s 'right))
(define panel-count (length (layout-panel-ids (state-layout s6))))
(define focus-pid (editor-focus-panel-id s6))
(define focus-vid (editor-focus-view-id s6))
(define-values (s7 _a7) (editor-open-file! ed s6 b))
(define vb (editor-placement-view-id s7))
(define-values (s8 _a8) (editor-placement-commit ed s7))
(define saved-panel-ids (sorted-panel-ids (state-layout s8)))
(define saved-focus-pid (editor-focus-panel-id s8))
(define saved-focus-vid (editor-focus-view-id s8))
(define saved-current-area (state-current-area s8))
(define saved-a-text (engine-doc-text (editor-engine ed) (resource-doc-id (find-resource (state-resources s8) a-path))))
(define saved-a-line (engine-view-point-line (editor-engine ed) va))
(define saved-a-col (engine-view-point-column (editor-engine ed) va))

;; 保存（写两次，确认 .bak）。
(check-true (save-editor-session! ed s8 #:workspace-root root))
(check-true (save-editor-session! ed s8 #:workspace-root root))
(define dir (default-session-dir root))
(check-true (file-exists? (session-file-path dir)))
(check-true (file-exists? (session-backup-path dir)))

;; 磁盘格式：resource 在 workspace 内时存相对路径。
(define data (read-session-data (session-file-path dir)))
(check-true (list? data))
(define resources-sexpr (let ([p (assq 'resources data)]) (and p (cdr p))))
(define a-rec
  (for/first ([r (in-list resources-sexpr)]
              #:when (equal? (let ([p (assq 'doc-id r)]) (and p (cdr p)))
                             (resource-doc-id (find-resource (state-resources s8) a-path))))
    r))
(check-true (and a-rec #t))
(define path-sexpr (let ([p (assq 'path a-rec)]) (and p (cdr p))))
(check-eq? (let ([p (assq 'kind path-sexpr)]) (and p (cdr p))) 'workspace)
(check-equal? (let ([p (assq 'value path-sexpr)]) (and p (cdr p))) "a.rkt")

;; 新 app 启动后恢复。
(define-values (ed2 s9) (make-editor-app #:workspace-root root))
(define s10 (load-editor-session! ed2 s9 #:workspace-root root))

(check-equal? (sorted-panel-ids (state-layout s10)) saved-panel-ids)
(check-equal? (editor-focus-panel-id s10) saved-focus-pid)
(check-equal? (editor-focus-view-id s10) saved-focus-vid)
(check-equal? (state-current-area s10) saved-current-area)

(define ra (find-resource (state-resources s10) a-path))
(define rb (find-resource (state-resources s10) b-path))
(check-true (and ra rb #t))
(check-equal? (engine-doc-text (editor-engine ed2) (resource-doc-id ra)) saved-a-text)
(check-true (resource-dirty? ra (engine-doc-version (editor-engine ed2) (resource-doc-id ra))))
(check-false (resource-dirty? rb (engine-doc-version (editor-engine ed2) (resource-doc-id rb))))
(check-equal? (engine-view-point-line (editor-engine ed2) va) saved-a-line)
(check-equal? (engine-view-point-column (editor-engine ed2) va) saved-a-col)
(define restored-va (engine-view-object (editor-engine ed2) va))
(check-equal? (point-line (selection-anchor (view-primary restored-va))) 1)
(check-equal? (point-column (selection-anchor (view-primary restored-va))) 0)
(check-equal? (point-line (selection-head (view-primary restored-va))) 1)
(check-equal? (point-column (selection-head (view-primary restored-va))) 2)

;; undo 栈不跨进程。
(check-false (buffer-can-undo? (view-buffer (engine-view-object (editor-engine ed2) va))))

;; 多编辑区：切到 area 2 打开 c，保存后当前 area / inactive area 都要恢复。
(define s11 (editor-switch-area s8 2))
(check-equal? (state-current-area s11) 2)
(define-values (s12 _a12) (editor-open-file! ed s11 c))
(define vc (editor-placement-view-id s12))
(define-values (s13 _a13) (editor-placement-commit ed s12))
(define area2-focus-pid (editor-focus-panel-id s13))
(define area2-focus-vid (editor-focus-view-id s13))
(check-true (save-editor-session! ed s13 #:workspace-root root))

(define-values (ed3 s14) (make-editor-app #:workspace-root root))
(define s15 (load-editor-session! ed3 s14 #:workspace-root root))
(check-equal? (state-current-area s15) 2)
(check-equal? (editor-focus-panel-id s15) area2-focus-pid)
(check-equal? (editor-focus-view-id s15) area2-focus-vid)
(check-true (hash-has-key? (state-areas s15) 1))
(define va-loc (editor-view-location s15 va))
(check-true (and va-loc #t))
(check-equal? (view-location-area-id va-loc) 1)
(define rc (find-resource (state-resources s15) c-path))
(check-true (and rc #t))
(check-equal? (engine-doc-text (editor-engine ed3) (resource-doc-id rc)) "sea\n")

;; 当前 session 损坏时回退到 .bak（上一代：area 1）。
(display-to-file "not a session" (session-file-path dir) #:exists 'truncate)
(define-values (ed4 s16) (make-editor-app #:workspace-root root))
(define s17 (load-editor-session! ed4 s16 #:workspace-root root))
(check-equal? (state-current-area s17) 1)
(check-true (pair? (resources-list (state-resources s17))))

(delete-directory/files root)
(displayln "edit-tui/test/persist-minimal.rkt: ok")
