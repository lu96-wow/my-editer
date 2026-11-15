#lang racket

;;; C 语言能力：模式 / 词法 / 高亮 / 增量颜色 / 补全 / 文档 / 插件集成。

(require rackunit
         racket/file
         (except-in racket/list range)
         racket/path
         "../core/api.rkt"
         "../core/face/api.rkt"
         "../editor/host-api.rkt"
         "../editor/mode.rkt"
         "../lang/c/api.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/docs/api.rkt"
         "../edit.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt"
         "../host/event.rkt")

;;; ════════════════ 模式 / 词法 ════════════════

(check-eq? (doc-mode-for "a.c" "") 'c)
(check-eq? (doc-mode-for "a.h" "") 'c)
(check-eq? (doc-mode-for #f "#include <stdio.h>\n") 'c)

(define sample
  (string-append "#include <stdio.h>\n"
                 "int main(void) {\n"
                 "  // comment\n"
                 "  printf(\"hi %d\\n\", 42);\n"
                 "  return 0;\n"
                 "}\n"))

(define toks (c-tokenize sample))
(check-equal? (map c-token-kind (list-ref toks 0)) '(preprocessor))
(check-equal? (map c-token-kind (list-ref toks 1))
              '(type whitespace identifier punct type punct whitespace punct))
(check-true (for/or ([t (in-list (list-ref toks 2))])
              (eq? (c-token-kind t) 'comment)))
(check-equal? (c-identifier-at sample 3 4) "printf")
(check-false (member "comment" (c-symbols-in-text sample)))
(check-false (member "hi" (c-symbols-in-text sample)))

;;; ════════════════ 高亮 ════════════════

(define roles (c-highlight-text sample))
(check-eq? (vector-ref (list-ref roles 1) 0) 'syntax-type)
(check-eq? (vector-ref (list-ref roles 1) 4) 'syntax-function)
(check-eq? (vector-ref (list-ref roles 2) 2) 'syntax-comment)
(check-eq? (vector-ref (list-ref roles 3) 2) 'syntax-function)
(check-eq? (vector-ref (list-ref roles 4) 2) 'syntax-keyword)
(check-eq? (vector-ref (list-ref roles 0) 0) 'syntax-preprocessor)

;;; ════════════════ 增量颜色 ════════════════

(define cs (c-color-open sample))
(check-equal? (length (c-color-syntax-roles cs))
              (length (c-text-lines sample)))
(define sample2 (string-replace sample "return 0;" "return 1;"))
(define-values (cs2 dirty)
  (c-color-edit* cs sample2
                 (list (line-edit 4 5 4 5))))
(check-equal? dirty '(4))
(check-equal? (c-color-syntax-roles cs2)
              (c-color-syntax-roles (c-color-open sample2)))

;;; ════════════════ 补全 ════════════════

(define ctext "int main(void) {\n  prin\n  int my_var = 1;\n}\n")
(define cands (c-completion-at #f ctext 1 6))
(check-true (and (member "printf" cands) #t))
(define macro-cands (c-completion-at #f ctext 0 0))
(check-equal? macro-cands '())
(define open-cands
  (c-completion-at #f "int x = O_RD;\n" 0 12))
(check-true (and (member "O_RDONLY" open-cands) #t))
(define local-cands
  (c-completion-at #f "int my_var;\nmy_v" 1 4))
(check-true (and (member "my_var" local-cands) #t))

;; #include 头文件补全；sys/ 前缀要整体保留。
(define inc-text "#include <std")
(define header-cands
  (c-completion-at #f inc-text 0 (string-length inc-text)))
(check-true (and (member "stdio.h" header-cands) #t))
(check-equal? (c-completion-prefix inc-text 0 (string-length inc-text)) "std")
(define sys-text "#include <sys/st")
(check-equal? (c-completion-prefix sys-text 0 (string-length sys-text)) "sys/st")
(check-equal? (c-completion-at #f sys-text 0 (string-length sys-text))
              '("sys/stat.h"))
(check-equal? (car (c-header-completion-at "#include <" 0 (string-length "#include <")))
              "stdio.h")

;;; ════════════════ 本地文档 / 内置声明 ════════════════

(check-true
 (let ([s (c-local-def "static int foo(int x) {\n  return x + 1;\n}\n" "foo")])
   (and s (string-contains? s "foo"))))
;; 调用点不是本地定义。
(check-false (c-local-def "printf(\"x\");\n" "printf"))
(check-false (c-local-def "return printf(\"x\");\n" "printf"))
(check-false (c-local-def "return (int) printf(\"x\");\n" "printf"))
;; 数据层可替换；直接验证内置 entry，不依赖当前机器是否装了 printf(3)。
(define printf-entry (c-lib-entry-for "printf"))
(check-true (and printf-entry #t))
(check-equal? (c-lib-entry-header printf-entry) "stdio.h")
(check-true (and (string-contains? (c-lib-entry-signature printf-entry) "printf") #t))
(define printf-doc (c-docs-lines "printf"))
(check-true (list? printf-doc))
;; 不能把 man 1 的 shell printf 混进 C 文档。
(check-false (for/or ([l (in-list printf-doc)])
               (string-contains? l "format and print data")))
(check-true (list? (c-docs-lines "definitely_not_a_real_c_symbol")))

;;; ════════════════ indent ════════════════

(check-equal? (c-indent-for-newline "void f(void) {\n" 0 0) "")
(check-equal? (c-indent-for-newline "  int x;\n" 0 0) "  ")

;;; ════════════════ 插件集成：模式 / 着色 / 配对 / 补全 ════════════════

(define root (make-temporary-directory))
(define c-path (build-path root "demo.c"))
(display-to-file sample c-path #:exists 'replace)

(define-values (ed state0) (make-editor-app #:workspace-root root))
(define state1 (state-with-screen state0 (rect 0 0 80 24)))
(define-values (state2 _a1) (editor-open-file! ed state1 c-path))
(define c-vid (editor-placement-view-id state2))
(define-values (state3 _a2) (editor-placement-commit ed state2))
(define c-did (editor-view-doc-id ed c-vid))
(check-eq? (state-doc-mode state3 c-did) 'c)

;; render 会跑 c-color sync，把 face 写进 view。
(define-values (state4 _cache _bytes) (render-frame ed state3 #f))
(define int-face (editor-view-face-at ed c-vid 1 0))
(check-true (and int-face #t))
(check-eq? (face-fg int-face) 'syntax-type)
(define printf-face (editor-view-face-at ed c-vid 3 2))
(check-true (and printf-face #t))
(check-eq? (face-fg printf-face) 'syntax-function)

;; M-d / docs 服务 payload 带上 c mode，worker 才会走 man / 内置 C 索引。
(define docs-ps (state-plugin-state state4 'docs))
(define-values (state-docs _docs-ps _docs-actions)
  (docs-show-name! ed state4 docs-ps "printf"))
(define docs-job
  (for/first ([j (in-list (state-pending-jobs state-docs))]
              #:when (eq? (job-kind j) 'docs))
    j))
(check-true (and docs-job #t))
(check-eq? (last (job-payload docs-job)) 'c)

;; C 也走 pair：打开空 .c 文件，输入 { -> {}。
(define pair-path (build-path root "pair.c"))
(display-to-file "" pair-path #:exists 'replace)
(define-values (ed-p sp0) (make-editor-app #:workspace-root root))
(define sp1 (state-with-screen sp0 (rect 0 0 40 10)))
(define-values (sp2 _pa) (editor-open-file! ed-p sp1 pair-path))
(define p-vid (editor-placement-view-id sp2))
(define-values (sp3 _pb) (editor-placement-commit ed-p sp2))
(define-values (sp4 _pc) (editor-set-point! ed-p sp3 p-vid 0 0))
(define-values (sp5 _pd) (editor-insert! ed-p sp4 p-vid "{"))
(check-equal? (editor-view-text ed-p p-vid) "{}")

;; C-o 手动打开补全：候选包含 printf。
(define complete-path (build-path root "complete.c"))
(display-to-file "int main(void) {\n  prin\n}\n" complete-path #:exists 'replace)
(define-values (ed-c sc0) (make-editor-app #:workspace-root root))
(define sc0* (state-with-screen sc0 (rect 0 0 60 12)))
(define-values (sc0a _ca0) (editor-open-file! ed-c sc0* complete-path))
(define c-vid2 (editor-placement-view-id sc0a))
(define-values (sc1a _ca1) (editor-placement-commit ed-c sc0a))
(define-values (sc1 _ca)
  (editor-select! ed-c sc1a c-vid2
                  (selections-one (caret (point 1 6)))))
(define sc2 (handle-editor-event ed-c sc1 (key-event (key 'o 'ctrl))))
(define cps (state-plugin-state sc2 'completion))
(check-true (completion-state? cps))
(check-true (completion-state-open? cps))
(check-true (and (member "printf" (completion-state-candidates cps)) #t))

;; include 行补全经过 completion 插件：候选包含 stdio.h。
(define header-path (build-path root "header.c"))
(display-to-file "#include <std" header-path #:exists 'replace)
(define-values (ed-h sh0) (make-editor-app #:workspace-root root))
(define sh0* (state-with-screen sh0 (rect 0 0 60 12)))
(define-values (sh0a _ha0) (editor-open-file! ed-h sh0* header-path))
(define h-vid (editor-placement-view-id sh0a))
(define-values (sh1a _ha1) (editor-placement-commit ed-h sh0a))
(define hlen (string-length "#include <std"))
(define-values (sh1 _ha2)
  (editor-select! ed-h sh1a h-vid
                  (selections-one (caret (point 0 hlen)))))
(define sh2 (handle-editor-event ed-h sh1 (key-event (key 'o 'ctrl))))
(define hps (state-plugin-state sh2 'completion))
(check-true (completion-state? hps))
(check-true (and (member "stdio.h" (completion-state-candidates hps)) #t))

(delete-directory/files root)
(displayln "edit-tui/test/c-language.rkt: ok")
