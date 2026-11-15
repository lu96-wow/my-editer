#lang racket

;;; resources 面板：行投影 / sidebar tab / Enter 聚焦 view / dirty 标记。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../features/sidebar/api.rkt"
         "../core/command/api.rkt"
         "../core/layout/api.rkt"
         "../edit.rkt"
         "../host/event.rkt"
         "fixture.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt")

(define root (make-temporary-directory))
(define file (build-path root "one.rkt"))
(display-to-file "#lang racket\n(define x 1)\n" file #:exists 'replace)

(define-values (ed state) (make-test-editor))
(define s0 (state-with-workspace-root
            (state-with-screen state (rect 0 0 60 15))
            (resource-normalize-path root)))

;; 打开文件并提交 placement。
(define-values (s1 _a1) (editor-open-file! ed s0 file))
(define vid (editor-placement-view-id s1))
(define-values (s2 _a2) (editor-placement-commit ed s1))

;; 第一帧触发 resources sync。
(define-values (s3 _c3 _b3) (render-frame ed s2 #f))
(define text1 (engine-view-text (editor-engine ed) 4))
(check-true (string-contains? text1 "test.rkt"))
;; status bar 也显示 workspace root 内的相对路径。
(define status-text (engine-view-text (editor-engine ed) 2))
(check-true (string-contains? status-text "one.rkt"))
(check-false (string-contains? status-text (path->string file)))
;; workspace root 内：显示相对路径，不显示绝对路径。
(check-true (string-contains? text1 "one.rkt"))
(check-false (string-contains? text1 (path->string file)))
(check-true (string-contains? text1 (format "  view ~a" vid)))

;; 焦点到 sidebar，再切到 resources tab。
(define-values (s4 _a4) (editor-focus! ed s3 'left))
(check-equal? (editor-focus-panel-kind s4) 'sidebar)
(check-equal? (editor-focus-view-id s4) 3)
(define-values (s5 _a5) (editor-cycle-sidebar-view! ed s4))
(check-equal? (editor-focus-view-id s5) 4)

;; Enter 一个 view 行：聚焦该 view。
(define resources-plugin
  (for/first ([p (in-list (editor-plugins ed))]
              #:when (eq? (plugin-id p) 'resources))
    p))
(define table (plugin-commands resources-plugin))
(define-values (status enter-cmd)
  (command-table-lookup table (list (key 'enter))))
(check-eq? status 'command)
(check-true (guarded-command? enter-cmd))
(check-true ((guarded-command-when-fn enter-cmd) ed s5
                                                (state-plugin-state s5 'resources)))

(define lines (string-split (engine-view-text (editor-engine ed) 4) "\n" #:trim? #f))
(define view-line
  (for/first ([line (in-list lines)] [i (in-naturals)]
              #:when (string-contains? line (format "view ~a" vid)))
    i))
(check-not-false view-line)
(engine-set-view-cursor! (editor-engine ed) 4 view-line #:column 0)
(define-values (s6 _ps6 _a6)
  ((guarded-command-run enter-cmd) ed s5
   (state-plugin-state s5 'resources)))
(check-equal? (editor-focus-panel-kind s6) 'editor)
(check-equal? (editor-focus-view-id s6) vid)

;; 编辑后 resources 面板出现 dirty *。
(define-values (s7 _a7) (editor-insert! ed s6 vid "!"))
(define-values (s8 _c8 _b8) (render-frame ed s7 #f))
(check-true (string-contains? (engine-view-text (editor-engine ed) 4) "*"))

;; C-v n / C-v d：resources 面板内创建 / 删除 view。
(define-values (s9 _a9) (editor-focus! ed s8 'left))
(check-equal? (editor-focus-view-id s9) 4)
(define-values (s10 _c10 _b10) (render-frame ed s9 #f))
(define r0 (state-resource-for-view s10 vid))
(define views0 (resource-views r0))
(engine-set-view-cursor! (editor-engine ed) 4 view-line #:column 0)
(define s11 (handle-editor-event ed s10 (key-event (key 'v 'ctrl))))
(define s12 (handle-editor-event ed s11 (key-event (key 'n))))
(check-equal? (editor-focus-view-id s12) 4)
(define r1 (state-resource-for-view s12 vid))
(define views1 (resource-views r1))
(check-equal? (length views1) (add1 (length views0)))
(define new-vid (for/first ([v (in-list views1)] #:unless (memv v views0)) v))
(check-not-false new-vid)
(check-not-false (engine-view-object (editor-engine ed) new-vid))

(define-values (s13 _c13 _b13) (render-frame ed s12 #f))
(define lines2 (string-split (engine-view-text (editor-engine ed) 4) "\n" #:trim? #f))
(define new-view-line
  (for/first ([line (in-list lines2)] [i (in-naturals)]
              #:when (string-contains? line (format "view ~a" new-vid)))
    i))
(check-not-false new-view-line)
(engine-set-view-cursor! (editor-engine ed) 4 new-view-line #:column 0)
(define s14 (handle-editor-event ed s13 (key-event (key 'v 'ctrl))))
(define s15 (handle-editor-event ed s14 (key-event (key 'd))))
(check-equal? (editor-focus-view-id s15) 4)
(check-false (engine-view-object (editor-engine ed) new-vid))
(check-equal? (resource-views (state-resource-for-view s15 vid)) views0)

;; buffer 行 C-v d 不删 view。
(define-values (s16 _c16 _b16) (render-frame ed s15 #f))
(define buffer-line
  (for/first ([line (in-list (string-split (engine-view-text (editor-engine ed) 4)
                                          "\n" #:trim? #f))]
              [i (in-naturals)]
              #:when (and (string-contains? line "one.rkt")
                          (not (string-contains? line "view"))))
    i))
(check-not-false buffer-line)
(engine-set-view-cursor! (editor-engine ed) 4 buffer-line #:column 0)
(define s17 (handle-editor-event ed s16 (key-event (key 'v 'ctrl))))
(define s18 (handle-editor-event ed s17 (key-event (key 'd))))
(check-true (string-contains? (state-flash s18) "select a view"))
(check-equal? (resource-views (state-resource-for-view s18 vid)) views0)

(delete-directory/files root)
(displayln "edit-tui/test/resources-panel.rkt: ok")
