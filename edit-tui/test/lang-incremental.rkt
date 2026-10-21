#lang racket

;;; lang/racket 的增量测试：
;;;   color-open / color-edit      行级高亮 + 同词色
;;;   analyze-source / analysis-edit 顶层 form 级解析
;;;   workspace-apply-changes      跨 buffer 解析缓存

(require rackunit
         racket/list
         "../lang/racket/api.rkt"
         "../source/api.rkt")

;;; ════════════════ 着色增量 ════════════════

;; 普通行编辑：只重算脏行，未变行的 role 向量可以结构共享。
(define c-text1 "#lang racket\n(define x 1)\n(define (f y) (+ x y))\n")
(define c1 (color-open c-text1))
(define c-text2 "#lang racket\n(define x 2)\n(define (f y) (+ x y))\n")
(define c2 (color-edit c1 c-text2 (list (line-edit 1 2 1 2))))
(check-eq? c1 (color-edit c1 c-text1 '()))
(check-equal? (vector-ref (list-ref (color-syntax-roles c2) 1) 1)
              'syntax-keyword-def)
(check-eq? (list-ref (color-syntax-roles c1) 2)
           (list-ref (color-syntax-roles c2) 2))

;; 跨行状态：去掉块注释开始后，后面的行必须被传播重扫。
(define b-text1 "#| open\n\n(define x 1)\n")
(define b1 (color-open b-text1))
(define b-text2 "plain\n\n(define x 1)\n")
(define b2 (color-edit b1 b-text2 (list (line-edit 0 1 0 1))))
(check-equal? (vector-ref (list-ref (color-syntax-roles b2) 2) 1)
              'syntax-keyword-def)
;; 插入行：行数变化，块注释状态仍然对齐。
(define b-text3 "plain\n\n\n(define x 1)\n")
(define b3 (color-edit b2 b-text3 (list (line-edit 2 2 2 3))))
(check-equal? (color-line-count b3) 5)
(check-equal? (vector-ref (list-ref (color-syntax-roles b3) 3) 1)
              'syntax-keyword-def)

;; 同词色也跟着增量；未变行共享同一个 role 向量。
(check-eq? (list-ref (color-word-roles c1) 2)
           (list-ref (color-word-roles c2) 2))

;; 括号状态跨行传播：去掉第一行的左括号后，第二行必须从 depth 0 重扫。
(define br-text1 "(a\n[b]\n)")
(define br1 (color-open br-text1))
(check-equal? (vector-ref (list-ref (color-bracket-roles br1) 1) 0)
              'bracket-depth-1)
(define br-text2 "a\n[b]\n)")
(define br2 (color-edit br1 br-text2 (list (line-edit 0 1 0 1))))
(check-equal? (vector-ref (list-ref (color-bracket-roles br2) 1) 0)
              'bracket-depth-0)

;;; ════════════════ 解析增量 ════════════════

(define a-text1
  (string-append "#lang racket\n"
                 "(define x 1)\n"
                 "\n"
                 "(define (f y) (+ x y))\n"))
(define a1 (analyze-source #f a-text1))
(check-equal? (module-analysis-definitions a1) '(x f))
(check-not-false (member "y" (module-analysis-bindings a1)))
(check-equal? (length (module-analysis-entries a1)) 2)

;; 改第一个 form 的常量：第二个 form 原样保留。
(define a-text2
  (string-append "#lang racket\n"
                 "(define x 2)\n"
                 "\n"
                 "(define (f y) (+ x y))\n"))
(define a2 (analysis-edit a1 #f a-text2 (list (line-edit 1 2 1 2))))
(check-equal? (module-analysis-definitions a2) '(x f))
(check-equal? (map form-entry-form (module-analysis-entries a2))
              '((define x 2) (define (f y) (+ x y))))
(check-false (eq? (car (module-analysis-entries a1))
                  (car (module-analysis-entries a2))))
(check-eq? (cadr (module-analysis-entries a1))
           (cadr (module-analysis-entries a2)))

;; 改函数参数：局部绑定名跟着变。
(define a-text3
  (string-append "#lang racket\n"
                 "(define x 2)\n"
                 "\n"
                 "(define (f z) (+ x z))\n"))
(define a3 (analysis-edit a2 #f a-text3 (list (line-edit 3 4 3 4))))
(check-not-false (member "z" (module-analysis-bindings a3)))
(check-false (member "y" (module-analysis-bindings a3)))

;; 在空白处插入新顶层 form：保守回退全量，但结果必须正确。
(define a-text4
  (string-append "#lang racket\n"
                 "(define x 2)\n"
                 "(define y 3)\n"
                 "\n"
                 "(define (f z) (+ x z))\n"))
(define a4 (analysis-edit a3 #f a-text4 (list (line-edit 2 2 2 3))))
(check-equal? (module-analysis-definitions a4) '(x y f))

;;; ════════════════ workspace 跨 buffer 增量 ════════════════

(define ws-a-text
  (string-append "#lang racket\n"
                 "(provide foo)\n"
                 "(define (foo x) x)\n"))
(define ws-b-text
  (string-append "#lang racket\n"
                 "(require \"a.rkt\")\n"
                 "(define (bar x) (foo x))\n"))

(define ws0 (workspace-set-doc workspace-empty 'a "/tmp/a.rkt" ws-a-text))
(define ws1 (workspace-set-doc ws0 'b "/tmp/b.rkt" ws-b-text))
(check-equal? (workspace-export-names ws1 'a) '("foo"))
(check-not-false (member "foo" (workspace-local-pool ws1 'b)))

;; a 改名：只重解析 a 的顶层 form；b 不需要重解析，但依赖查询看到新导出。
(define ws-a-text2
  (string-append "#lang racket\n"
                 "(provide baz)\n"
                 "(define (baz x) x)\n"))
(define ws2 (workspace-apply-changes
             ws1 'a "/tmp/a.rkt" ws-a-text2
             #:version 'v2
             #:edits (list (line-edit 1 2 1 2)
                           (line-edit 2 3 2 3))))
(check-equal? (workspace-export-names ws2 'a) '("baz"))
(check-not-false (member "baz" (workspace-local-pool ws2 'b)))
;; b 的文本里仍出现过 foo：作为“本地词”保留，但已不是导入导出。
(check-not-false (member "foo" (workspace-local-pool ws2 'b)))
(check-false (docs-local ws2 'b "foo"))
(check-not-false (docs-local ws2 'b "baz"))


;;; ════════════════ workspace 直接消费 source snapshot ════════════════

(define src-a (buffer-source 'a "/tmp/a.rkt" ws-a-text #:version 'sv1))
(define ws-source (workspace-set-source workspace-empty src-a))
(check-equal? (workspace-export-names ws-source (source-snapshot-id src-a)) '("foo"))

(define src-a2 (buffer-source 'a "/tmp/a.rkt" ws-a-text2 #:version 'sv2))
(define ws-source2
  (workspace-apply-source-changes
   ws-source src-a2
   (list (line-edit 1 2 1 2) (line-edit 2 3 2 3))))
(check-equal? (workspace-export-names ws-source2 (source-snapshot-id src-a2)) '("baz"))


;;; ════════════════ 本地词池（当前 buffer 的 symbol token） ════════════════

(define word-text
  (string-append "#lang racket\n"
                 "(define x 1)\n"
                 "(foo-bar x)\n"
                 ";; comment-word\n"
                 "\"string-word\"\n"))
(define ws-word
  (workspace-set-doc workspace-empty 'w "/tmp/w.rkt" word-text))
(define ctx-word
  (make-completion-context "/tmp/w.rkt" word-text
                           #:workspace ws-word #:id 'w))
(check-not-false (member "foo-bar" (completion-candidates/local ctx-word "foo")))
(check-not-false (member "x" (completion-candidates/local ctx-word "")))
;; 注释 / 字符串里的词不进入本地词池。
(check-false (member "comment-word" (completion-candidates/local ctx-word "com")))
(check-false (member "string-word" (completion-candidates/local ctx-word "str")))

(displayln "edit-tui-rebuild/test/lang-incremental.rkt: ok")
