#lang racket

;;; editor tab 切换 / close buffer。

(require rackunit
         racket/file
         racket/path
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../host/final.rkt"
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
(define s0 (state-with-area state (rect 0 0 60 15)))

;; split 出的新 view 也登记到同一个 resource。
(define-values (s-split _a1) (editor-split! ed s0 'right))
(define editor-r (state-resource-for-doc s-split 1))
(check-equal? (length (resource-views editor-r)) 2)

;; 打开文件并放入当前 editor panel -> 同一 panel 有两个 view。
(define f1 (make-file "one.txt" "one"))
(define-values (s1 _a2) (editor-open-file! ed s-split f1))
(define vid1 (editor-placement-view-id s1))
(define-values (s2 _a3) (editor-placement-commit ed s1))
(check-equal? (editor-focus-view-id s2) vid1)
(define panel-id (editor-focus-panel-id s2))
(define panel (layout-panel (state-layout s2) panel-id))
(check-equal? (length (p:panel-views panel)) 2)

;; C-x p / C-x n 切 tab。
(define-values (s3 _a4) (editor-cycle-editor-view! ed s2 -1))
(check-equal? (editor-focus-view-id s3) 10)
(define-values (s4 _a5) (editor-cycle-editor-view! ed s3 1))
(check-equal? (editor-focus-view-id s4) vid1)

;; close buffer（clean）：删 resource / view，panel active 回到另一个 view。
(define-values (s5 _a6) (editor-close-buffer-command ed s4))
(check-false (state-resource-for-view s5 vid1))
(check-false (engine-view-object (editor-engine ed) vid1))
(check-equal? (editor-focus-view-id s5) 10)

;; dirty close + n：不保存，直接关闭。
(define f2 (make-file "two.txt" "two"))
(define-values (s6 _a7) (editor-open-file! ed s5 f2))
(define vid2 (editor-placement-view-id s6))
(define-values (s7 _a8) (editor-placement-commit ed s6))
(define-values (s8 _a9) (editor-insert! ed s7 vid2 "!"))
(define-values (s9 _a10) (editor-close-buffer-command ed s8))
(check-true (editor-input-active? s9))
(check-eq? (editor-input-kind s9) 'close-confirm)
(define-values (s9a _a11) (editor-input-insert s9 "n"))
(define-values (s10 _a12) (editor-input-submit! ed s9a))
(check-false (editor-input-active? s10))
(check-false (state-resource-for-view s10 vid2))
(check-equal? (file->string f2) "two")

;; dirty close + y：保存后关闭。
(define f3 (make-file "three.txt" "three"))
(define-values (s11 _a13) (editor-open-file! ed s10 f3))
(define vid3 (editor-placement-view-id s11))
(define-values (s12 _a14) (editor-placement-commit ed s11))
(define-values (s13 _a15) (editor-insert! ed s12 vid3 "!"))
(define-values (s14 _a16) (editor-close-buffer-command ed s13))
(define-values (s14a _a17) (editor-input-insert s14 "y"))
(define-values (s15 _a18) (editor-input-submit! ed s14a))
(check-false (state-resource-for-view s15 vid3))
(check-true (string-contains? (file->string f3) "!"))

(delete-directory/files root)
(displayln "edit-tui/test/tabs.rkt: ok")
