#lang racket

;;; filetree 展开 / 折叠 / 隐藏文件。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../host/app-layout.rkt"
         "../core/command/api.rkt"
         "../plugins/filetree/plugin.rkt")

(define root (make-temporary-directory))
(display-to-file "a" (build-path root "a.txt") #:exists 'replace)
(void (make-directory (build-path root "dir")))
(display-to-file "b" (build-path root "dir" "b.txt") #:exists 'replace)
(display-to-file "h" (build-path root ".hidden") #:exists 'replace)

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 3 "*filetree*" ""))
(void (engine-create-view! engine 3 3))

(define plugin (make-filetree-plugin #:view 3 #:root root))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1 #:sidebar-view 3))
(define state
  (make-app-state #:plugin-states (plugins->states (list plugin))
                     #:area (rect 0 0 60 15)
                     #:layout layout))

(define table (plugin-commands plugin))
(define (cmd seq)
  (define-values (status value) (command-table-lookup table seq))
  (check-eq? status 'command)
  (check-true (guarded-command? value))
  value)

(define enter (cmd (list (key 'enter))))
(define toggle-hidden (cmd (list (key 'h 'ctrl))))

(define (ps-of st)
  (state-plugin-state st 'filetree))

(define (rows-of st)
  (filetree-state-rows (ps-of st)))

(define (run-cmd ed st c)
  (define-values (s ps actions) ((guarded-command-run c) ed st (ps-of st)))
  (values (state-set-plugin-state s 'filetree ps) actions))

(define (line-of st path)
  (for/first ([row (in-list (rows-of st))] [i (in-naturals)]
              #:when (equal? (car row) path))
    i))

;; 初始：不展开目录、不显示 .hidden
(define s1 (run-plugin-syncs ed state))
(define text1 (engine-view-text engine 3))
(check-true (string-contains? text1 "a.txt"))
(check-false (string-contains? text1 "▸"))
(check-false (string-contains? text1 "▾"))
;; root 子项缩进两格，目录不带 "/" 后缀。
(define dir-row
  (for/first ([row (in-list (rows-of s1))]
              #:when (equal? (car row) (build-path root "dir")))
    row))
(check-not-false dir-row)
(check-equal? (caddr dir-row) "  dir")
(check-false (string-contains? text1 ".hidden"))
(check-false (string-contains? text1 "b.txt"))

;; 焦点移到 sidebar
(define-values (s2 _a2) (editor-focus! ed s1 'left))
(check-equal? (editor-focus-panel-kind s2) 'sidebar)
(check-true ((guarded-command-when-fn enter) ed s2 (ps-of s2)))

;; root 也可以展开 / 折叠：折叠后只剩 root 行。
(engine-set-view-cursor! engine 3 0 #:column 0)
(define-values (s-root _ar) (run-cmd ed s2 enter))
(define s-root-sync (run-plugin-syncs ed s-root))
(check-false (string-contains? (engine-view-text engine 3) "a.txt"))
(engine-set-view-cursor! engine 3 0 #:column 0)
(define-values (s-root2 _ar2) (run-cmd ed s-root-sync enter))
(define s-root2-sync (run-plugin-syncs ed s-root2))
(check-true (string-contains? (engine-view-text engine 3) "a.txt"))

;; 展开 dir
(define dir-line (line-of s-root2-sync (build-path root "dir")))
(check-not-false dir-line)
(engine-set-view-cursor! engine 3 dir-line #:column 0)
(define-values (s3 _a3) (run-cmd ed s-root2-sync enter))
(define s4 (run-plugin-syncs ed s3))
(check-true (string-contains? (engine-view-text engine 3) "b.txt"))
;; 子文件再缩进两格。
(check-true (string-contains? (engine-view-text engine 3) "    b.txt"))

;; 折叠 dir
(define dir-line2 (line-of s4 (build-path root "dir")))
(check-not-false dir-line2)
(engine-set-view-cursor! engine 3 dir-line2 #:column 0)
(define-values (s5 _a5) (run-cmd ed s4 enter))
(define s6 (run-plugin-syncs ed s5))
(check-false (string-contains? (engine-view-text engine 3) "b.txt"))

;; 显示 .hidden
(define-values (s7 _a7) (run-cmd ed s6 toggle-hidden))
(define s8 (run-plugin-syncs ed s7))
(check-true (string-contains? (engine-view-text engine 3) ".hidden"))

;; 自定义 hidden-entry? 过滤规则。
(define root2 (make-temporary-directory))
(display-to-file "a" (build-path root2 "a.txt") #:exists 'replace)
(display-to-file "b" (build-path root2 "b.rkt") #:exists 'replace)
(define engine2 (make-engine))
(void (engine-create-buffer! engine2 1 "test" ""))
(void (engine-create-view! engine2 1 1))
(void (engine-create-buffer! engine2 3 "*filetree*" ""))
(void (engine-create-view! engine2 3 3))
(define plugin2
  (make-filetree-plugin #:view 3 #:root root2
                        #:hidden-entry?
                        (λ (p) (string-suffix? (path->string p) ".txt"))))
(define ed2 (make-editor #:engine engine2
                         #:registry (make-hook-registry '())
                         #:plugins (list plugin2)))
(define layout2 (make-editor-layout #:editor-view 1 #:sidebar-view 3))
(define state2 (make-app-state #:plugin-states (plugins->states (list plugin2))
                                  #:area (rect 0 0 60 15)
                                  #:layout layout2))
(define s2b (run-plugin-syncs ed2 state2))
(define text2 (engine-view-text engine2 3))
(check-false (string-contains? text2 "a.txt"))
(check-true (string-contains? text2 "b.rkt"))
(delete-directory/files root2)

(displayln "edit-tui/test/filetree-expand.rkt: ok")
