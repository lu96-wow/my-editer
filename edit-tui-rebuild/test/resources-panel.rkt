#lang racket

;;; resources 面板：行投影 / sidebar tab / Enter 聚焦 view / dirty 标记。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/layout/api.rkt"
         "../host/final.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt")

(define root (make-temporary-directory))
(define file (build-path root "one.rkt"))
(display-to-file "#lang racket\n(define x 1)\n" file #:exists 'replace)

(define-values (ed state) (make-demo-editor))
(define s0 (struct-copy editor-state state [area (rect 0 0 60 15)]))

;; 打开文件并提交 placement。
(define-values (s1 _a1) (editor-open-file! ed s0 file))
(define vid (editor-placement-view-id s1))
(define-values (s2 _a2) (editor-placement-commit ed s1))

;; 第一帧触发 resources sync。
(define-values (s3 _c3 _b3) (render-frame ed s2 #f))
(define text1 (engine-view-text (editor-engine ed) 4))
(check-true (string-contains? text1 "scratch.rkt"))
(check-true (string-contains? text1 (path->string file)))
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
                                                (editor-state-plugin-state s5 'resources)))

(define lines (string-split (engine-view-text (editor-engine ed) 4) "\n" #:trim? #f))
(define view-line
  (for/first ([line (in-list lines)] [i (in-naturals)]
              #:when (string-contains? line (format "view ~a" vid)))
    i))
(check-not-false view-line)
(engine-set-view-cursor! (editor-engine ed) 4 view-line #:column 0)
(define-values (s6 _ps6 _a6)
  ((guarded-command-run enter-cmd) ed s5
   (editor-state-plugin-state s5 'resources)))
(check-equal? (editor-focus-panel-kind s6) 'editor)
(check-equal? (editor-focus-view-id s6) vid)

;; 编辑后 resources 面板出现 dirty *。
(define-values (s7 _a7) (editor-insert! ed s6 vid "!"))
(define-values (s8 _c8 _b8) (render-frame ed s7 #f))
(check-true (string-contains? (engine-view-text (editor-engine ed) 4) "*"))

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/resources-panel.rkt: ok")
