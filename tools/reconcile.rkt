#lang racket

;;; tools/reconcile.rkt —— 文档 ↔ 可达面对账
;;;
;;; 可达面白名单 = **core/api.rkt**（低层公开面）+ **core/editor.rkt**（editor 平台）。
;;; 内部机制（platform/state.rkt、platform/write.rkt、platform/reaction.rkt、各层内部模块）
;;; 可达但不在白名单里，文档提到它们时必须按「内部」讲。
;;;
;;; 做法：扫两份 .md **表格行第一格**的首个反引号 token，逐个分类：
;;;   api      —— 在 core/editor.rkt 的导出里（消费者可用）✓
;;;   internal —— 在 core 某个模块里存在（机制/内部）
;;;   pattern  —— 形如 `buffer-*` 的通配/占位
;;;   concept  —— 概念词、符号字面量（none/free/…）、字段名
;;;   nowhere  —— 哪里都没有 ⇒ **真漂移**（改名/删了没改文档），退出码 1
;;;
;;; 用法：`racket tools/reconcile.rkt`（打印报告；有漂移则报错退出非零）
;;;       同时是 `raco test .` 的一个检查（`module+ test`：安静，有漂移才失败）。

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

;; 消费者可达面 = 低层公开面 core/api.rkt + editor 平台 core/editor.rkt
(define api-syms
  (set-subtract (syms-of (list `(file ,(string-append root "core/api.rkt"))
                               `(file ,(string-append root "core/editor.rkt"))))
                base-syms))

;; 模块内部（含机制/工具/组合层）：用来把 "internal" 与 "nowhere" 分开。
;; 排除 tools/（否则会把本脚本自己当模块 require，无限递归）。
(define (rkt-files dir)
  (for/fold ([acc '()]) ([p (in-list (directory-list dir))])
    (define full (path->string (build-path dir p)))
    (cond
      [(directory-exists? full)
       (if (regexp-match? #rx"/(compiled|[.]git|tools|core-history|io-temp)$" full) acc (append (rkt-files full) acc))]
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
;; 形如 `buffer-*`、`editor-*-at` 的占位/通配，只在文档表格里出现，不是绑定。
(define pattern-rx #rx"[*]")
;; 概念词 / 符号字面量 / 字段名：文档表格用它开头是**有意**的（讲语义，不是 API 名）。
(define concept-tokens
  '("face" "cursor" "tick" "top" "left-col" "top-seg"
    "payload" "none" "map" "leader" "clamp" "free" "follow"
    "buffer-id" "view-id" "buffer" "window" "editor" "op" "desc" "report"
    "data" "lambda" "apply" "state" "event" "run" "screen"))

(define (classify tok)
  (cond [(regexp-match? pattern-rx tok) 'pattern]
        [(member tok concept-tokens) 'concept]
        [(not (regexp-match? id-rx tok)) 'not-ident]
        [(memq (string->symbol tok) api-syms) 'api]
        [(memq (string->symbol tok) all-syms) 'internal]
        [else 'nowhere]))

(define (table-tokens path)
  (for/fold ([acc '()]) ([line (in-list (file->lines path))])
    (define cell (and (regexp-match? #rx"^ *\\|" line) (first-cell line)))
    (if (not cell)
        acc
        (let ([ms (regexp-match* #rx"`[^`]+`" cell)])
          (if (pair? ms)
              (cons (let ([t (car ms)]) (substring t 1 (sub1 (string-length t)))) acc)
              acc)))))

(define docs (list "ARCHITECTURE.md" "MANUAL.md"))

(define (analyze md)
  (define toks (remove-duplicates (table-tokens (string-append root md))))
  (values toks
          (for/fold ([h (hash)]) ([t (in-list toks)])
            (hash-update h (classify t) (lambda (l) (cons t l)) '()))))

(define (drift-tokens)
  (remove-duplicates
   (append* (for/list ([md (in-list docs)])
              (define-values (_toks groups) (analyze md))
              (hash-ref groups 'nowhere '())))))

;; 报告（只在 module+ main 打印；作为测试跑时保持安静）
(define (report)
  (for ([md (in-list docs)])
    (define-values (toks groups) (analyze md))
    (displayln (format "\n~a：表格第一格 ~a 个不同名字" md (length toks)))
    (for ([k (in-list (sort (hash-keys groups) symbol<?))])
      (displayln (format "  ~a: ~a" k (length (hash-ref groups k)))))
    (for ([k (in-list '(internal nowhere))])
      (define l (sort (hash-ref groups k '()) string<?))
      (when (pair? l)
        (displayln (format "  【~a】：~a" k (string-join l " "))))))
  (displayln (format "\n消费者可达面（core/api.rkt + core/editor.rkt）：~a 个名字" (length api-syms)))
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
