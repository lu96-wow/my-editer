#lang racket

;;; editor tab 切换 / close buffer。

(require rackunit
         racket/file
         racket/path
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../edit.rkt"
         "fixture.rkt"
         "../features/input/api.rkt"
         "../features/placement/api.rkt"
         "../host/close.rkt"
         "../host/prompt.rkt"
         "../host/open.rkt")

(define root (make-temporary-directory))
(define (make-file name text)
  (define p (build-path root name))
  (display-to-file text p #:exists 'replace)
  p)

(define-values (ed state) (make-test-editor))
(define s0 (state-with-screen state (rect 0 0 60 15)))

;; split 只创建空 panel：不新建 view，也不复用源 panel 的 view。
(define-values (s-split _a1) (editor-split! ed s0 'right))
(define empty-panel-id (editor-focus-panel-id s-split))
(check-not-equal? empty-panel-id 'editor)
(check-false (editor-focus-view-id s-split))
(define editor-r (state-resource-for-doc s-split 1))
(check-equal? (length (resource-views editor-r)) 1)
(check-equal? (length (p:panel-views
                       (layout-panel (state-layout s-split) empty-panel-id)))
              0)

;; 打开两个文件并放进当前空 panel，形成两个 tab。
(define f1 (make-file "one.txt" "one"))
(define-values (s1 _a2) (editor-open-file! ed s-split f1))
(define vid1 (editor-placement-view-id s1))
(define-values (s2 _a3) (editor-placement-commit ed s1))
(check-equal? (editor-focus-view-id s2) vid1)
(define panel-id (editor-focus-panel-id s2))
(check-equal? (length (p:panel-views (layout-panel (state-layout s2) panel-id)))
              1)

(define f2 (make-file "two.txt" "two"))
(define-values (s3 _a3b) (editor-open-file! ed s2 f2))
(define vid2 (editor-placement-view-id s3))
(define-values (s4 _a4) (editor-placement-commit ed s3))
(check-equal? (editor-focus-view-id s4) vid2)
(check-equal? (length (p:panel-views (layout-panel (state-layout s4) panel-id)))
              2)

;; C-x p / C-x n 切 tab。
(define-values (s5 _a5) (editor-cycle-editor-view! ed s4 -1))
(check-equal? (editor-focus-view-id s5) vid1)
(define-values (s6 _a6) (editor-cycle-editor-view! ed s5 1))
(check-equal? (editor-focus-view-id s6) vid2)

;; close buffer（clean）：删 resource / view，panel active 回到另一个 view。
(define-values (s7 _a7) (editor-cycle-editor-view! ed s6 -1))
(define-values (s8 _a8) (editor-close-buffer-command ed s7))
(check-false (state-resource-for-view s8 vid1))
(check-false (engine-view-object (editor-engine ed) vid1))
(check-equal? (editor-focus-view-id s8) vid2)

;; dirty close + n：不保存，直接关闭。
(define-values (s9 _a9) (editor-insert! ed s8 vid2 "!"))
(define-values (s10 _a10) (editor-close-buffer-command ed s9))
(check-true (editor-input-active? s10))
(check-eq? (editor-input-kind s10) 'close-confirm)
(define-values (s10a _a11) (editor-input-insert s10 "n"))
(define-values (s11 _a12) (editor-input-submit! ed s10a))
(check-false (editor-input-active? s11))
(check-false (state-resource-for-view s11 vid2))
(check-equal? (file->string f2) "two")

;; dirty close + y：保存后关闭。
(define f3 (make-file "three.txt" "three"))
(define-values (s12 _a13) (editor-open-file! ed s11 f3))
(define vid3 (editor-placement-view-id s12))
(define-values (s13 _a14) (editor-placement-commit ed s12))
(define-values (s14 _a15) (editor-insert! ed s13 vid3 "!"))
(define-values (s15 _a16) (editor-close-buffer-command ed s14))
(define-values (s15a _a17) (editor-input-insert s15 "y"))
(define-values (s16 _a18) (editor-input-submit! ed s15a))
(check-false (state-resource-for-view s16 vid3))
(check-true (string-contains? (file->string f3) "!"))

(delete-directory/files root)
(displayln "edit-tui/test/tabs.rkt: ok")
