#lang racket

;;; edit-tui/lang/racket 的纯 API 测试：
;;;   lex / highlight / word-color / source / completion / docs
;;;
;;; 这些测试不 require main.rkt，也不碰 engine / app / boot。

(require rackunit
         racket/string
         "../lang/racket/api.rkt")

;;; ════════════════ 类型判定 ════════════════

(check-true (racket-file? "a.rkt"))
(check-true (racket-file? "a.scrbl"))
(check-false (racket-file? "a.txt"))
(check-true (racket-text? "#lang racket\n(define x 1)"))
(check-false (racket-text? "hello"))

;;; ════════════════ 词法 ════════════════

(define t0 "(define x 1) ; hi")
(define lines0 (tokenize t0))
(check-equal? (map token-kind (car lines0))
              '(paren symbol whitespace symbol whitespace number paren
                      whitespace comment))
(check-equal? (map (lambda (t) (substring t0 (token-start t) (token-end t)))
                   (car lines0))
              '("(" "define" " " "x" " " "1" ")" " " "; hi"))

;; 字符串 / 字符字面量：字符 #\( 不应被当成括号。
(define t1 "#\\( \"a b\"")
(define toks1 (car (tokenize t1)))
(check-equal? (map token-kind toks1) '(char whitespace string))

;; 块注释跨行 + 可嵌套
(define t2 "#| outer\n #| inner |#\n done |# (list 1)")
(define lines2 (tokenize t2))
(check-equal? (length lines2) 3)
(check-equal? (token-kind (car (list-ref lines2 0))) 'comment)
(check-equal? (token-kind (car (list-ref lines2 1))) 'comment)
(check-true (for/or ([t (in-list (list-ref lines2 2))])
              (eq? (token-kind t) 'comment)))
(check-true (for/or ([t (in-list (list-ref lines2 2))])
              (eq? (token-kind t) 'symbol)))

;; 字符串跨行
(define lines3 (tokenize "\"a\nb\""))
(check-equal? (map token-kind (map car lines3)) '(string string))

;; 光标处标识符
(check-equal? (identifier-at "(define foo 1)" 0 9) "foo")
(check-equal? (identifier-at "(define foo 1)" 0 11) "foo") ; 词尾
(check-false (identifier-at "(define foo 1)" 0 0))

;;; ════════════════ 高亮 ════════════════

(define h (highlight-text "(define x 1) ; note\n\"s\" 42"))
(define h0 (list-ref h 0))
(check-equal? (vector-ref h0 1) 'syntax-keyword-def)
(check-equal? (vector-ref h0 10) 'syntax-number)
(check-equal? (vector-ref h0 13) 'syntax-comment)
(check-equal? (vector-ref (list-ref h 1) 0) 'syntax-string)
(check-equal? (vector-ref (list-ref h 1) 4) 'syntax-number)
(check-equal? (highlight-role "(lambda (x) x)" 0 1) 'syntax-keyword-binding)
(check-false (highlight-role "(foo bar)" 0 1))

;;; ════════════════ 同词着色 ════════════════

(check-equal? (word-color-index "foo") (word-color-index "foo"))
(check-equal? (word-color-role "foo") (word-color-role "foo"))
(check-not-false (memq (word-color-role "foo")
                         (for/list ([i (in-range word-color-count)])
                           (string->symbol (format "word-color-~a" i)))))
(define wc (word-color-text "(foo foo bar)"))
(check-equal? (vector-ref (car wc) 1) (vector-ref (car wc) 5))
(check-false (vector-ref (car wc) 0)) ; '(' 不是词

;;; ════════════════ 括号深度 ════════════════

(define bd (bracket-depth-text "(a [b] c)\n\"(x)\" ; (y)\n(f"))
(check-equal? (vector-ref (list-ref bd 0) 0) 'bracket-depth-0) ; 外层左括号
(check-equal? (vector-ref (list-ref bd 0) 1) 'bracket-depth-0) ; 外层内容
(check-equal? (vector-ref (list-ref bd 0) 3) 'bracket-depth-1) ; 内层左括号
(check-equal? (vector-ref (list-ref bd 0) 4) 'bracket-depth-1) ; 内层内容
(check-equal? (vector-ref (list-ref bd 0) 5) 'bracket-depth-1) ; 内层右括号
(check-equal? (vector-ref (list-ref bd 0) 8) 'bracket-depth-0) ; 外层右括号
;; 字符串 / 注释里的括号不改变栈，也没有背景。
(check-false (vector-ref (list-ref bd 1) 0))
(check-false (vector-ref (list-ref bd 1) 8))
;; 下一行仍从外层深度重新开始。
(check-equal? (vector-ref (list-ref bd 2) 0) 'bracket-depth-0)
(check-equal? (vector-ref (list-ref bd 2) 1) 'bracket-depth-0)

;; 跨行括号栈
(define bd-cross (bracket-depth-text "(\n[x]\n)"))
(check-equal? (vector-ref (list-ref bd-cross 0) 0) 'bracket-depth-0)
(check-equal? (vector-ref (list-ref bd-cross 1) 0) 'bracket-depth-1)
(check-equal? (vector-ref (list-ref bd-cross 1) 1) 'bracket-depth-1)
(check-equal? (vector-ref (list-ref bd-cross 2) 0) 'bracket-depth-0)

;;; ════════════════ 源码 / 补全 ════════════════

(define src
  (string-append "#lang racket\n"
                 "(require racket/list)\n"
                 "(define (foobar x) x)\n"
                 "(provide foobar)\n"))

(define-values (lang forms) (module-context src))
(check-equal? lang 'racket)
(check-not-false (memq 'racket/list (requires-of-forms lang forms)))
(check-not-false (memq 'foobar (definitions-of-forms forms)))
(check-not-false (member "foobar" (provides-of-forms src)))

(check-equal? (completion-prefix "  foo" 0 5) "foo")
(check-equal? (completion-prefix "(foo" 0 4) "foo")

(define ctx (make-completion-context #f src))
(check-true (completion-context? ctx))
(check-not-false (member "foobar" (completion-candidates/local ctx "foo")))
(check-not-false (member "first" (completion-candidates/required ctx "fi")))
(check-not-false (member "foobar" (completion-candidates ctx "foo")))
(check-equal? (completion-insert-text "foobar" "foo") "bar")

;; require / #lang 模块路径上下文
(check-true (module-path-context? "#lang racket\n(require racket/li" 1 16))
(check-true (module-path-context? "#lang racket/li" 0 13))
(check-false (module-path-context? "#lang racket\n(define x 1)" 1 3))

;;; ════════════════ 文档 ════════════════

(check-equal? (local-def src (quote foobar)) "(define (foobar x) x)")
(check-false (local-def src (quote missing)))

(define doc-map (docs-for "map" #:modules (list (quote racket/base))))
(check-not-false doc-map)
(check-true (string? (doc-signature doc-map)))
(check-true (string-contains? (doc->text doc-map) "map"))
(check-equal? (result->doc (doc->result doc-map)) doc-map)


;;; ════════════════ 局部绑定（Racket 绑定形式） ════════════════

(define local-src
  (string-append "#lang racket\n"
                 "(define (f x)\n"
                 "  (let ([y 1])\n"
                 "    (lambda (z)\n"
                 "      (for ([i (in-range 3)])\n"
                 "        (match x [(list a b) (list a b i z y)])))))\n"))
(define local-names (local-binding-names local-src))
(for ([n (in-list '("f" "x" "y" "z" "i" "a" "b"))])
  (check-not-false (member n local-names) n))

;;; ════════════════ workspace：跨 buffer 缓存 / 依赖 ════════════════

(define a-text
  (string-append "#lang racket\n"
                 "(provide foo)\n"
                 "(define (foo x) x)\n"))
(define b-text
  (string-append "#lang racket\n"
                 "(require \"a.rkt\")\n"
                 "(define (bar x) (foo x))\n"
                 "(let ([loc 1]) loc)\n"))

(define ws-a (workspace-set-doc workspace-empty 'a "/tmp/a.rkt" a-text))
(define ws-b (workspace-set-doc ws-a 'b "/tmp/b.rkt" b-text))

;; 解析缓存：同一版本复用同一 analysis 值。
(check-eq? (workspace-analysis ws-b 'b)
           (workspace-analysis (workspace-set-doc ws-b 'b "/tmp/b.rkt" b-text) 'b))

;; a 的导出被 b 看到；b 的本地绑定也进来。
(check-equal? (workspace-export-names ws-b 'a) '("foo"))
(check-not-false (member "foo" (workspace-local-pool ws-b 'b)))
(check-not-false (member "loc" (workspace-local-pool ws-b 'b)))
(check-equal? (map document-entry-path (workspace-imported-local-docs ws-b 'b))
              '("/tmp/a.rkt"))

;; 跨 buffer docs：foo 来自 a.rkt。
(define foo-doc (docs-local ws-b 'b "foo"))
(check-not-false foo-doc)
(check-equal? (doc-signature foo-doc) "(define (foo x) x)")


;; all-from-out 跨 buffer：a 的导出通过 b 再导出。
(define re-export-text
  (string-append "#lang racket\n"
                 "(require \"a.rkt\")\n"
                 "(provide (all-from-out \"a.rkt\"))\n"))
(define ws-re (workspace-set-doc ws-b 're "/tmp/re.rkt" re-export-text))
(check-not-false (member "foo" (workspace-export-names ws-re 're)))

;; a 改了 provide -> b 不需要重新 parse，但依赖查询必须看到新导出。
(define a2-text
  (string-append "#lang racket\n"
                 "(provide baz)\n"
                 "(define (baz x) x)\n"))
(define ws-b2 (workspace-set-doc ws-b 'a "/tmp/a.rkt" a2-text))
(check-equal? (workspace-export-names ws-b2 'a) '("baz"))
(check-not-false (member "baz" (workspace-local-pool ws-b2 'b)))
;; b 的文本里仍出现过 foo：作为“本地词”保留，但已不是导入导出。
(check-not-false (member "foo" (workspace-local-pool ws-b2 'b)))
(check-false (docs-local ws-b2 'b "foo"))

;; completion 也走 workspace：b 中 foo 的候选来自 a 的 provide。
(define b-complete
  (string-append "#lang racket\n"
                 "(require \"a.rkt\")\n"
                 "(define (bar x) (fo"))
(check-not-false
 (member "foo"
         (completion-at "/tmp/b.rkt" b-complete 2 18
                        #:workspace ws-b #:id 'b)))

;; 编辑中的残缺顶层 form 不能让分析器崩（只收集能收集的部分）。
(for ([t (in-list '("(define)"
                    "(match)"
                    "(struct)"
                    "(let)"
                    "(define-values)"
                    "(match x)"
                    "(provide except-out)"))])
  (check-not-false (analyze-source #f t)))

(displayln "edit-tui-rebuild/test/lang.rkt: ok")
