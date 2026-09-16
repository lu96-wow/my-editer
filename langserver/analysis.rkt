#lang racket

(require racket/string rackunit)

;;; analysis.rkt —— Racket 源码分析（纯函数，数据 → lambda → 数据，无 I/O）
;;;
;;; 这是「语言服务器」的智能部分，只做三件事：
;;;   - module-diagnostics : 源码 → 诊断（读/展开错误，含行列）
;;;   - module-definitions  : 源码 → 顶层定义清单 (name line col)
;;;   - complete            : 源码 + 前缀 → 补全候选
;;;
;;; 坐标约定：0-based 行列（与编辑器 core 层一致）。
;;; 限制：诊断用 eval（展开 + 实例化），会执行模块顶层代码；只做语法检查的
;;;       安全展开需要 drracket/check-syntax，暂不引入该依赖。

(provide
 (struct-out diagnostic)
 module-diagnostics
 module-definitions
 complete)

(struct diagnostic (line col end-line end-col severity message) #:transparent)
;; severity : 'error | 'warning

;;; ---------- 读源码（支持 #lang）----------

(define (read-module-syntax src)
  (define p (open-input-string src))
  (port-count-lines! p)
  (parameterize ([read-accept-reader #t])
    (read-syntax (string->path "module.rkt") p)))

;; syntax → 0-based 行列（syntax-line 是 1-based，syntax-column 是 0-based）
(define (syntax->line-col stx)
  (define l (and stx (syntax-line stx)))
  (define c (and stx (syntax-column stx)))
  (if (and l c (>= l 1))
      (values (sub1 l) c)
      (values 0 0)))

;;; ---------- 诊断 ----------

(define (module-diagnostics src)
  ;; 1) 读错误（括号不匹配等）
  (define-values (syn read-err) (try-read src))
  (cond
    [read-err (list read-err)]
    [else
     ;; 2) 展开/实例化错误（语法、宏展开、顶层运行时）
     (define ns (make-base-namespace))
     (with-handlers
         ([exn:fail:syntax?
           (lambda (e) (list (exn->diagnostic e)))]
          [exn:fail?
           (lambda (e)
             (list (diagnostic 0 0 0 0 'error (exn-message e))))])
       (parameterize ([current-namespace ns])
         (eval syn))
       '())]))

(define (try-read src)
  (with-handlers
      ([exn:fail:read?
        (lambda (e)
          (values #f (diagnostic 0 0 0 0 'error (exn-message e))))])
    (values (read-module-syntax src) #f)))

(define (exn->diagnostic e)
  (define exprs (exn:fail:syntax-exprs e))
  (define stx (and (pair? exprs) (car exprs)))
  (define-values (l c) (syntax->line-col stx))
  (define span (and stx (syntax-span stx)))
  ;; 简化为单行区间 [c, c+span)
  (diagnostic l c l (+ c (or span 0)) 'error (exn-message e)))

;;; ---------- 定义清单 ----------

(define (module-definitions src)
  (define syn (with-handlers ([exn:fail? (lambda (e) #f)])
                (read-module-syntax src)))
  (cond
    [(not syn) '()]
    [else
     (filter values
       (for/list ([f (in-list (module-body-forms syn))])
         (define nm (definition-name f))
         (and nm
              (let-values ([(l c) (syntax->line-col nm)])
                (list (syntax->datum nm) l c)))))]))

;; (module name lang body ...) → body forms；#lang 会把 body 包成 (#%module-begin ...)，拆开
(define (module-body-forms syn)
  (define lst (syntax->list syn))
  (cond
    [(and (pair? lst) (>= (length lst) 3)
          (eq? 'module (syntax-e (car lst))))
     (define body (cdddr lst))
     (if (and (= (length body) 1)
              (pair? (syntax-e (car body)))
              (eq? '#%module-begin (syntax-e (car (syntax-e (car body))))))
         (cdr (syntax-e (car body)))
         body)]
    [else '()]))

;; 顶层定义 → 名字 syntax；非定义 → #f
;; 用 syntax-e（按符号名 case）而非 syntax-parse 字面量：read-syntax 产出的
;; identifier 无词法绑定，与 pattern 里带绑定的 define 不 free-identifier=?，
;; 所以按 datum（符号名）匹配才正确。
(define (definition-name f)
  (define e (syntax-e f))
  (and (pair? e)
       (let* ([head (syntax-e (car e))]
              [second (and (pair? (cdr e)) (cadr e))])
         (case head
           [(define define-syntax define-syntax-rule)
            (and second (def-name-of second))]
           [(struct)
            (and second (def-name-of second))]
           [else #f]))))

;; (define x ...) 的 x；或 (define (f ...) ...) 的 f；或 (struct (pt super) ...) 的 pt
(define (def-name-of second)
  (cond
    [(identifier? second) second]
    [(and (pair? (syntax-e second))
          (identifier? (car (syntax-e second))))
     (car (syntax-e second))]
    [else #f]))

;;; ---------- 补全 ----------

;; 常用 racket/base 绑定（演示用；真实实现可换 namespace-mapped-symbols）
(define common-bindings
  '(define define-values lambda let let* letrec let-values if cond case and or not
    map foldl foldr filter for/list for/hash for/vector
    list cons car cdr null? pair? list? length append reverse
    string string-append string-length substring string->symbol symbol->string
    number? integer? + - * / = < > <= >= add1 sub1
    displayln printf error apply values compose
    struct require provide begin when unless match
    hash hash-set hash-ref hash-remove hash-has-key?))

(define (complete src line col prefix)
  (define own (map car (module-definitions src)))
  (define names (remove-duplicates (append common-bindings own)))
  (for/list ([n (in-list names)]
             #:when (symbol? n)
             #:when (string-prefix? (symbol->string n) prefix))
    (symbol->string n)))

;;; ---------- 测试 ----------

(module+ test
  (define src
    (string-append
     "(module t racket/base\n"
     "  (define x 1)\n"
     "  (define (square n) (* n n))\n"
     "  (struct pt (x y) #:transparent)\n"
     "  (define-syntax-rule (twice e) (begin e e))\n"
     ")\n"))

  ;; 定义清单（名字 + 行号；列号只验 >0，避免逐字符计数脆弱）
  (define defs (module-definitions src))
  (check-equal? (map car defs) '(x square pt twice))
  (check-equal? (map cadr defs) '(1 2 3 4))
  (check-true (for/and ([d (in-list defs)]) (> (caddr d) 0)))

  ;; #lang racket 源码（body 被 #%module-begin 包裹，也要能正确解析）
  (define lang-src "#lang racket\n(define x 1)\n(define (sq n) (* n n))\n")
  (check-equal? (map car (module-definitions lang-src)) '(x sq))
  (check-equal? (map cadr (module-definitions lang-src)) '(1 2))

  ;; 无错误 → 空诊断
  (check-equal? (module-diagnostics src) '())

  ;; 语法错误 → 有诊断，位置在错误行
  (define bad "(module t racket/base\n  (define x)\n)\n")
  (define diags (module-diagnostics bad))
  (check-true (pair? diags))
  (check-equal? (diagnostic-line (car diags)) 1)

  ;; #lang 源码的语法错误也能定位
  (define bad-lang "#lang racket\n(define x 1)\n(define y)\n")
  (define diags2 (module-diagnostics bad-lang))
  (check-true (pair? diags2))
  (check-equal? (diagnostic-line (car diags2)) 2)

  ;; 读错误（括号不匹配）
  (define unbal "(module t racket/base\n  (define x 1)\n")
  (check-true (pair? (module-diagnostics unbal)))

  ;; 补全
  (check-not-false (member "square" (complete src 0 0 "squ")))
  (check-not-false (member "map" (complete src 0 0 "ma")))
  (check-equal? (complete src 0 0 "zzz-not-exist") '())

  (displayln "analysis.rkt: all tests passed"))
