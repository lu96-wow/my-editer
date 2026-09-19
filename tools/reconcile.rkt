#lang racket

;; tools/reconcile.rkt —— 文档 ↔ 可达面对账（ARCHITECTURE §8.5 C/E）
;;
;; 做法：扫两份 .md **表格行第一格**的首个反引号 token，逐个分类：
;;   api      —— 在 core/api.rkt 的显式白名单里（消费者可用）✓
;;   internal —— 只在模块内部（文档里提到它必须说明「内部」，见 MANUAL §5/§6 的注）
;;   nowhere  —— 哪里都没有 ⇒ **真漂移**（改名/删了没改文档），退出码 1
;;
;; 用法：`racket tools/reconcile.rkt`（打印报告；有漂移则报错退出非零）
;;       同时是 `raco test .` 的一个检查（`module+ test`：安静，有漂移才失败）。
;; 要点（踩过的坑）：① 只取**第一格**——行内其它反引号多是概念词、字段名、局部变量
;; （`cursor`、`left-col`、`pl`…），用「行内首个反引号」会误报一堆；
;; ② 比对集合要含消费层模块（`history.rkt`/`main.rkt`），否则 §8.5 的账本名字会误报。

(require racket/list racket/runtime-path)

;; 项目根从**本文件自身**推导（而不是 cwd）：`raco test .` 把它当子模块跑时 cwd 不一定是根。
(define-runtime-path here "reconcile.rkt")
(define root (string-append (path->string (simplify-path (build-path (path-only here) ".."))) "/"))

(define (syms-of reqs)
  (define ns (make-base-namespace))
  (parameterize ([current-namespace ns])
    (for ([r (in-list reqs)]) (namespace-require r))
    (namespace-mapped-symbols)))

(define base-syms (syms-of '()))
(define api-syms
  (set-subtract (syms-of (list `(file ,(string-append root "core/api.rkt")))) base-syms))

;; 模块内部（含消费层）：用来把 "internal" 与 "nowhere" 分开。
;; 注意排除 `tools/` —— 否则会把本脚本自己当模块 require（无限递归）。
(define (rkt-files dir)
  (for/fold ([acc '()]) ([p (in-list (directory-list dir))])
    (define full (path->string (build-path dir p)))
    (cond
      [(directory-exists? full)
       (if (regexp-match? #rx"/(compiled|[.]git|tools|[.]qwen)$" full) acc (append (rkt-files full) acc))]
      [(regexp-match? #rx"[.]rkt$" full) (cons full acc)]
      [else acc])))
(define all-syms
  (remove-duplicates
   (append* (for/list ([f (in-list (rkt-files root))])
              (set-subtract (syms-of (list `(file ,f))) base-syms)))))

(define (index-of-char s ch [from 0])
  (for/first ([i (in-range from (string-length s))] #:when (char=? (string-ref s i) ch)) i))
(define (first-cell line)
  (define i (index-of-char line #\|))
  (and i (let ([j (index-of-char line #\| (add1 i))]) (and j (substring line (add1 i) j)))))

(define id-rx #rx"^[a-zA-Z][a-zA-Z0-9]*[-a-zA-Z0-9<>=?!*]*$")
(define pattern-tokens
  '("make-*" "*-open" "*-of-*" "*-ref" "*-count" "*-line-count" "*-get" "*-at" "*-set-*"
    "add" "remove" "delete" "*-many" "*-batch" "*-trusted" "*-apply-edit" "*-check"))
;; 概念词 / 字段名 / 术语：文档表格用它开头是**有意**的（讲语义，不是 API 名）。
;; 这些不是绑定，也永远不该是——所以单独列出而不是塞进上面的模式行。
(define concept-tokens
  '("face" "cursor" "dirty" "modified?" "left-col" "top" "presentation" "restrict" "point" "patch"))

(define (table-tokens path)
  (for/fold ([acc '()]) ([line (in-list (file->lines path))])
    (define cell (and (regexp-match? #rx"^ *\\|" line) (first-cell line)))
    (if (not cell)
        acc
        (let ([ms (regexp-match* #rx"`[^`]+`" cell)])
          (if (pair? ms)
              (cons (let ([t (car ms)]) (substring t 1 (sub1 (string-length t)))) acc)
              acc)))))

(define (classify tok)
  (cond [(member tok pattern-tokens) 'pattern]
        [(member tok concept-tokens) 'concept]
        [(not (regexp-match? id-rx tok)) 'not-ident]
        [(memq (string->symbol tok) api-syms) 'api]
        [(memq (string->symbol tok) all-syms) 'internal]
        [else 'nowhere]))

(define (analyze md)
  (define toks (remove-duplicates (table-tokens (string-append root md))))
  (values toks
          (for/fold ([h (hash)]) ([t (in-list toks)])
            (hash-update h (classify t) (lambda (l) (cons t l)) '()))))

(define (drift-tokens)
  (remove-duplicates
   (append* (for/list ([md (in-list (list "ARCHITECTURE.md" "MANUAL.md"))])
              (define-values (toks groups) (analyze md))
              (hash-ref groups 'nowhere '())))))

;; 报告（只在 module+ main 打印；作为测试跑时保持安静）
(define (report)
  (for ([md (in-list (list "ARCHITECTURE.md" "MANUAL.md"))])
    (define-values (toks groups) (analyze md))
    (displayln (format "\n~a：表格第一格 ~a 个不同名字" md (length toks)))
    (for ([k (in-list (sort (hash-keys groups) symbol<?))])
      (displayln (format "  ~a: ~a" k (length (hash-ref groups k)))))
    (for ([k (in-list '(internal nowhere))])
      (define l (sort (hash-ref groups k '()) string<?))
      (when (pair? l)
        (displayln (format "  【~a】：~a" k (string-join l " "))))))
  (displayln (format "\n消费者可达面（core/api.rkt 白名单）：~a 个名字" (length api-syms)))
  (displayln (if (pair? (drift-tokens))
                 "== 有真漂移：上面【nowhere】的名字在项目里不存在 =="
                 "== 无漂移：所有表格名字要么可达、要么是模块内部 ==")))

(module+ main
  (report)
  (define d (drift-tokens))
  (when (pair? d)
    (error 'reconcile "文档 ↔ 可达面有漂移（项目里不存在的名字）：~a" d)))

(module+ test
  (require rackunit)
  ;; 作为 `raco test .` 的一部分跑：漂移即测试失败（安静，失败才吵）
  (check-equal? (drift-tokens) '() "文档表格里的名字必须可达、或是模块内部/概念词"))