#lang racket

;;; save / quit 输入流程：
;;;   C-s 无 path -> save-path -> 写文件
;;;   C-s 有 path -> save-confirm -> 写文件
;;;   C-q q / C-q s dirty -> quit-confirm y/n -> 保存/跳过 -> quit-action

(require rackunit
         racket/file
         racket/path
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../edit.rkt"
         "fixture.rkt"
         "../features/input/api.rkt"
         "../host/prompt.rkt"
         "../host/event.rkt")

(define root (make-temporary-directory))
(define target (build-path root "saved.rkt"))

(define-values (ed state) (make-test-editor))
(define s0 (state-with-screen state (rect 0 0 60 15)))
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))

(define vid (editor-focus-view-id s1))
(check-not-false vid)

;; C-s：fixture buffer 没有 path -> save-path
(define s2 (handle-editor-event ed s1 (key-event (key 's 'ctrl))))
(check-true (editor-input-active? s2))
(check-eq? (editor-input-kind s2) 'save-path)
(check-eq? (editor-focus-view-id s2) 5)
;; 输入栏投影到 status panel 的 input view。
(define-values (s2r _c2r _b2r) (render-frame ed s2 #f))
(check-equal? (engine-view-text (editor-engine ed) 5) "Save as: ")
(define-values (s2a _a2a) (editor-input-insert s2r (path->string target)))
(define-values (s2b actions2b) (editor-input-submit! ed s2a))
(check-false (editor-input-active? s2b))
(check-equal? (file->string target) (engine-view-text (editor-engine ed) vid))
(define r (state-resource-for-view s2b vid))
(check-equal? (resource-path r) (resource-normalize-path target))

;; 编辑 -> dirty -> C-s 走 save-confirm
(define-values (s3 _a3) (editor-insert! ed s2b vid "x"))
(define s4 (handle-editor-event ed s3 (key-event (key 's 'ctrl))))
(check-eq? (editor-input-kind s4) 'save-confirm)
(define-values (s4a _a4a) (editor-input-insert s4 "y"))
(define-values (s4b _a4b) (editor-input-submit! ed s4a))
(check-false (editor-input-active? s4b))
(check-true (string-contains? (file->string target) "x"))
(define r2 (state-resource-for-view s4b vid))
(check-false (resource-dirty? r2 (engine-doc-version (editor-engine ed)
                                                     (resource-doc-id r2))))

;; dirty -> C-q q -> n：不保存文件，且退出时不保存会话状态
(define-values (s5 _a5) (editor-insert! ed s4b vid "y"))
(define s5q (handle-editor-event ed s5 (key-event (key 'q 'ctrl))))
(check-false (state-quit? s5q))
(define s6 (handle-editor-event ed s5q (key-event (key 'q))))
(check-eq? (editor-input-kind s6) 'quit-confirm)
(check-false (state-save-session? s6))
(define-values (s6a _a6a) (editor-input-insert s6 "n"))
(define-values (s6b actions6b) (editor-input-submit! ed s6a))
(check-false (editor-input-active? s6b))
(check-true (for/or ([a (in-list actions6b)]) (quit-action? a)))
(check-false (string-contains? (file->string target) "y"))

;; dirty -> C-q s -> y：保存文件并 quit；退出时保存会话状态
(define-values (s7 _a7) (editor-insert! ed s6b vid "z"))
(define s7q (handle-editor-event ed s7 (key-event (key 'q 'ctrl))))
(define s8 (handle-editor-event ed s7q (key-event (key 's))))
(check-true (state-save-session? s8))
(define-values (s8a _a8a) (editor-input-insert s8 "y"))
(define-values (s8b actions8b) (editor-input-submit! ed s8a))
(check-true (for/or ([a (in-list actions8b)]) (quit-action? a)))
(check-true (string-contains? (file->string target) "z"))

;; 不 dirty -> C-q q 直接 quit，不保存会话
(define s8bq (handle-editor-event ed s8b (key-event (key 'q 'ctrl))))
(define s9 (handle-editor-event ed s8bq (key-event (key 'q))))
(check-true (state-quit? s9))
(check-false (state-save-session? s9))

;; 不 dirty -> C-q s 直接 quit，并保存会话状态
(define-values (ed2 state2) (make-test-editor))
(define q1 (handle-editor-event ed2 state2 (key-event (key 'q 'ctrl))))
(check-false (state-quit? q1))
(define q2 (handle-editor-event ed2 q1 (key-event (key 's))))
(check-true (state-quit? q2))
(check-true (state-save-session? q2))

;; 窗口关闭按默认“保存会话”处理，即使之前的状态是 C-q q 取消后的 #f。
(define-values (ed3 state3) (make-test-editor))
(define sq (handle-editor-event ed3
                               (state-with-save-session state3 #f)
                               (quit-event)))
(check-true (state-quit? sq))
(check-true (state-save-session? sq))

(delete-directory/files root)
(displayln "edit-tui/test/save-quit.rkt: ok")
