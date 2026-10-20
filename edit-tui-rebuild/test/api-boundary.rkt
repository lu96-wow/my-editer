#lang racket

;;; API 边界约束：
;;;
;;; 非实现层（main.rkt / api.rkt / demo / test / 未来 app）
;;; 不得直接 require 领域实现文件。
;;;
;;; 允许：
;;;   main.rkt
;;;   */api.rkt
;;;   外部 core/*
;;;
;;; 不允许：
;;;   layout/tree.rkt  layout/solve.rkt  layout/ops.rkt
;;;   panel/model.rkt
;;;   command/table.rkt
;;;   projection/geometry.rkt
;;;   ... 任何非 api.rkt 的领域实现文件

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string)

(define script (path->complete-path (find-system-path 'run-file)))
(define test-dir (path-only script))
(define root (simplify-path (build-path test-dir 'up)))

;; 这些目录内部是实现 + api 共存；不扫描它们的内部 require。
(define feature-dirs
  '("base" "panel" "config" "layout" "focus" "command" "projection" "face" "render" "resource" "filetree" "chrome" "app" "runtime" "edit"))

(define (feature-dir? rel)
  (for/or ([d (in-list feature-dirs)])
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

(define (api-path? str)
  (or (regexp-match? #rx"(^|/)api\\.rkt$" str)
      (regexp-match? #rx"(^|/)main\\.rkt$" str)))

(define (core-path? str)
  (regexp-match? #rx"(^|/)core/" str))

(define (impl-require? str)
  (and (not (api-path? str))
       (not (core-path? str))
       (or
        ;; 新结构：领域目录下的非 api 实现文件
        (regexp-match? #rx"(^|/)(base|panel|config|layout|focus|command|projection|face|render|resource|filetree|chrome|app|runtime)/[^/]+\\.rkt$" str)
        ;; 兼容旧结构
        (regexp-match? #rx"(^|/)(model|projection|command)/" str))))

;; 自检
(check-true (impl-require? "layout/tree.rkt"))
(check-true (impl-require? "../layout/solve.rkt"))
(check-true (impl-require? "../layout/ops.rkt"))
(check-true (impl-require? "../filetree/store.rkt"))
(check-true (impl-require? "../panel/model.rkt"))
(check-true (impl-require? "../projection/geometry.rkt"))
(check-true (impl-require? "../command/table.rkt"))
(check-true (impl-require? "../resource/model.rkt"))
(check-true (impl-require? "../face/model.rkt"))
(check-true (impl-require? "../render/core.rkt"))
(check-false (impl-require? "../layout/api.rkt"))
(check-false (impl-require? "../panel/api.rkt"))
(check-false (impl-require? "../main.rkt"))
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
              #:unless (feature-dir? rel)
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
