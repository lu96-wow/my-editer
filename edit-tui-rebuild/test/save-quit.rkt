#lang racket

;;; save / quit 输入流程：
;;;   C-s 无 path -> save-path -> 写文件
;;;   C-s 有 path -> save-confirm -> 写文件
;;;   C-q dirty -> quit-confirm y/n -> 保存/跳过 -> quit-action

(require rackunit
         racket/file
         racket/path
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/final.rkt"
         "../host/event.rkt")

(define root (make-temporary-directory))
(define target (build-path root "saved.rkt"))

(define-values (ed state) (make-demo-editor))
(define s0 (struct-copy editor-state state [area (rect 0 0 60 15)]))
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))

(define vid (editor-focus-view-id s1))
(check-not-false vid)

;; C-s：scratch 没有 path -> save-path
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
(define r (editor-state-resource-for-view s2b vid))
(check-equal? (resource-path r) (resource-normalize-path target))

;; 编辑 -> dirty -> C-s 走 save-confirm
(define-values (s3 _a3) (editor-insert! ed s2b vid "x"))
(define s4 (handle-editor-event ed s3 (key-event (key 's 'ctrl))))
(check-eq? (editor-input-kind s4) 'save-confirm)
(define-values (s4a _a4a) (editor-input-insert s4 "y"))
(define-values (s4b _a4b) (editor-input-submit! ed s4a))
(check-false (editor-input-active? s4b))
(check-true (string-contains? (file->string target) "x"))
(define r2 (editor-state-resource-for-view s4b vid))
(check-false (resource-dirty? r2 (engine-doc-version (editor-engine ed)
                                                     (resource-doc-id r2))))

;; dirty -> C-q -> n：不保存，quit-action
(define-values (s5 _a5) (editor-insert! ed s4b vid "y"))
(define s6 (handle-editor-event ed s5 (key-event (key 'q 'ctrl))))
(check-eq? (editor-input-kind s6) 'quit-confirm)
(define-values (s6a _a6a) (editor-input-insert s6 "n"))
(define-values (s6b actions6b) (editor-input-submit! ed s6a))
(check-false (editor-input-active? s6b))
(check-true (for/or ([a (in-list actions6b)]) (quit-action? a)))
(check-false (string-contains? (file->string target) "y"))

;; dirty -> C-q -> y：保存并 quit
(define-values (s7 _a7) (editor-insert! ed s6b vid "z"))
(define s8 (handle-editor-event ed s7 (key-event (key 'q 'ctrl))))
(define-values (s8a _a8a) (editor-input-insert s8 "y"))
(define-values (s8b actions8b) (editor-input-submit! ed s8a))
(check-true (for/or ([a (in-list actions8b)]) (quit-action? a)))
(check-true (string-contains? (file->string target) "z"))

;; 不 dirty -> C-q 直接 quit
(define s9 (handle-editor-event ed s8b (key-event (key 'q 'ctrl))))
(check-true (editor-state-quit? s9))

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/save-quit.rkt: ok")
