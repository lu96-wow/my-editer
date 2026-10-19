#lang racket

;;; API 边界约束：
;;;
;;; 除实现层（model / projection / command）和 api 层本身外，
;;; 其它代码（main / demo / test / 未来 app）不得直接 require 实现模块。
;;;
;;; 允许：
;;;   require main.rkt
;;;   require api/*
;;;   require ../core/*（外部 core）
;;;
;;; 不允许：
;;;   require ../model/*
;;;   require ../projection/*
;;;   require ../command/*

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string)

(define script (path->complete-path (find-system-path 'run-file)))
(define test-dir (path-only script))
(define root (simplify-path (build-path test-dir 'up)))

(define impl-dirs '("model" "projection" "command"))

(define (impl-dir? rel)
  (for/or ([d (in-list impl-dirs)])
    (regexp-match? (regexp (format "^~a/" (regexp-quote d))) rel)))

(define (all-strings x)
  (cond
    [(string? x) (list x)]
    [(list? x) (append* (for/list ([e (in-list x)]) (all-strings e)))]
    [else '()]))

(define (require-strings form)
  (cond
    [(and (list? form)
          (>= (length form) 1)
          (eq? (car form) 'require))
     (append* (for/list ([spec (in-list (cdr form))])
                (all-strings spec)))]
    [else '()]))

(define (read-forms path)
  (define text (regexp-replace #rx"^#lang[^\n]*\n" (file->string path) ""))
  (with-input-from-string text
    (λ ()
      (let loop ([acc '()])
        (define x (read))
        (if (eof-object? x)
            (reverse acc)
            (loop (cons x acc)))))))

(define (impl-require? str)
  (regexp-match? #rx"(^|/)(model|projection|command)/" str))

;; 自检：匹配器本身不能把 api / core 误判成实现层。
(check-true (impl-require? "model/layout.rkt"))
(check-true (impl-require? "../model/layout.rkt"))
(check-true (impl-require? "../projection/focus.rkt"))
(check-true (impl-require? "../command/table.rkt"))
(check-false (impl-require? "../api/layout.rkt"))
(check-false (impl-require? "../api/command.rkt"))
(check-false (impl-require? "../../core/view/panel.rkt"))

(define (rkt-files dir)
  (append*
   (for/list ([p (in-list (directory-list dir))])
     (define full (build-path dir p))
     (cond
       [(directory-exists? full) (rkt-files full)]
       [(regexp-match? #rx"\\.rkt$" (path->string full)) (list full)]
       [else '()]))))

(define all-rkt (rkt-files root))

(define violations
  (for*/list ([f (in-list all-rkt)]
              [rel (in-value (path->string (find-relative-path root f)))]
              #:unless (impl-dir? rel)
              #:unless (regexp-match? #rx"^api/" rel)
              [form (in-list (read-forms f))]
              [str (in-list (require-strings form))]
              #:when (impl-require? str))
    (list rel str)))

(unless (null? violations)
  (error 'api-boundary
         "以下文件越过 API 直接 require 实现模块：\n~a"
         (string-join (for/list ([v (in-list violations)])
                        (format "  ~a -> ~a" (car v) (cadr v)))
                      "\n")))

(displayln "edit-tui-rebuild/test/api-boundary.rkt: ok")
