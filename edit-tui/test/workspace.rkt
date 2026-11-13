#lang racket

;;; workspace：打开文档快照 -> completion / docs 跨 buffer。
;;;
;;; 覆盖：
;;;   · host 每帧把 Racket user doc 同步进 workspace；
;;;   · b.rkt require a.rkt 时，补全看到 a.rkt 当前 buffer 的 provide；
;;;   · M-d 本地预览能看到 a.rkt 里的 define；
;;;   · buffer 关闭后从 workspace 删除。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../lang/racket/api.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/docs/api.rkt"
         "../plugins/docs/model.rkt"
         "../host/open.rkt"
         "../host/close.rkt"
         "../host/event.rkt"
         "../features/placement/api.rkt"
         "../edit.rkt")

(define root (make-temporary-directory))
(define dep-path (build-path root "dep.rkt"))
(define main-path (build-path root "main.rkt"))

(display-to-file
 "#lang racket\n(provide dep-name)\n(define (dep-name) 42)\n"
 dep-path #:exists 'replace)

(define main-text "(require \"dep.rkt\")\n(define x dep-)\n")
(display-to-file main-text main-path #:exists 'replace)

(define-values (ed state)
  (make-editor-app #:workspace-root root
                   #:initial-text main-text
                   #:initial-name "main.rkt"
                   #:initial-path main-path))
(define s0 (state-with-area state (rect 0 0 60 15)))
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))

;;; ════════════════ 打开 dep，再切回 main ════════════════

(define-values (s2 _a2) (editor-open-file! ed s1 dep-path))
(check-true (editor-placement-active? s2))
(define dep-vid (editor-placement-view-id s2))
(define dep-r (state-resource-for-view s2 dep-vid))
(define dep-did (resource-doc-id dep-r))
(define-values (s3 _a3) (editor-placement-commit ed s2))
(define-values (s4 _a4) (editor-focus-view! ed s3 1))
(define-values (s5 _c5 _b5) (render-frame ed s4 #f))

;; 两个 Racket 文档都在 workspace。
(define ws (editor-workspace ed))
(check-not-false (workspace-doc ws 1))
(check-not-false (workspace-doc ws dep-did))
;; 没有文档变化时，重复 sync 不应重建 workspace。
(define-values (_s5b _c5b _b5b) (render-frame ed s5 #f))
(check-eq? (editor-workspace ed) ws)

;;; ════════════════ workspace 缺当前 doc：回退当前文本 ════════════════

(define fallback-text "#lang racket\n(define (foo) 1)\n(fo")
(define fallback-cands
  (completion-at #f fallback-text 2 3
                 #:workspace workspace-empty
                 #:id 999))
(check-not-false (member "foo" fallback-cands))

;;; ════════════════ completion：跨 buffer provide ════════════════

(engine-set-view-cursor! (editor-engine ed) 1 1 #:column 13)
(define s6 (handle-editor-event ed s5 (key-event (key 'o 'ctrl))))
(define c6 (state-plugin-state s6 'completion))
(check-true (completion-state-open? c6))
(check-not-false (member "dep-name" (completion-state-candidates c6)))

;;; ════════════════ docs：跨 buffer 本地定义 ════════════════

(define d0 (state-plugin-state s6 'docs))
(define-values (_s7 d1 _a7) (docs-show-name! ed s6 d0 "dep-name"))
(check-true (string-contains?
             (string-join (docs-state-lines d1) "\n")
             "dep-name"))

;;; ════════════════ 编辑 main：workspace 跟着 version 更新 ════════════════

(define-values (e1 _e-a1) (editor-insert! ed s6 1 " "))
(define-values (e2 _e-c2 _e-b2) (render-frame ed e1 #f))
(define ws2 (editor-workspace ed))
(check-not-eq? ws2 ws)
(check-equal? (document-entry-version (workspace-doc ws2 1))
              (editor-doc-version ed 1))

;;; ════════════════ 关闭 dep：从 workspace 删除 ════════════════

(define-values (s8 _a8) (editor-close-resource! ed e2 dep-did))
(define-values (s9 _c9 _b9) (render-frame ed s8 #f))
(define ws3 (editor-workspace ed))
(check-false (workspace-doc ws3 dep-did))
(check-not-false (workspace-doc ws3 1))

(delete-directory/files root)
(displayln "edit-tui/test/workspace.rkt: ok")
