#lang racket

;;; API 边界约束：
;;;
;;; 非实现层（main.rkt / */api.rkt / demo / test）
;;; 不得直接 require 领域实现文件。
;;;
;;; 允许：
;;;   main.rkt
;;;   */api.rkt
;;;   config/*（配置 / 键位绑定；不是领域实现）
;;;   core/skeleton.rkt（骨架公共入口）
;;;   外部 repo/core/*
;;;
;;; 不允许：
;;;   core/layout/tree.rkt  core/layout/solve.rkt  core/layout/ops.rkt
;;;   core/engine/store.rkt  core/engine/action.rkt
;;;   core/panel/model.rkt
;;;   core/command/table.rkt
;;;   core/projection/geometry.rkt
;;;   app/*.rkt  boot/*.rkt  edit/*.rkt  chrome/*.rkt  filetree/*.rkt ...
;;;   ... 任何非 api.rkt 的实现文件

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
  '("core" "boot" "config" "render" "filetree" "resources" "chrome" "app" "edit" "lang" "source"))

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

(define (external-core? str)
  (regexp-match? #rx"(^|/)\\.\\./\\.\\./core/" str))

(define (local-core-impl? str)
  (regexp-match?
   #rx"(^|/)core/(base|panel|layout|focus|face|resource|command|projection|engine)/[^/]+\\.rkt$"
   str))

(define (config-path? str)
  (regexp-match? #rx"(^|/)config/" str))

(define (domain-impl? str)
  (regexp-match? #rx"(^|/)(edit|chrome|filetree|resources|app|boot|render)/[^/]+\\.rkt$" str))

(define (impl-require? str)
  (and (not (api-path? str))
       (not (external-core? str))
       (not (config-path? str))
       (or (local-core-impl? str)
           (domain-impl? str))))

;; 自检
(check-true (impl-require? "core/layout/tree.rkt"))
(check-true (impl-require? "../core/layout/solve.rkt"))
(check-true (impl-require? "../core/layout/ops.rkt"))
(check-true (impl-require? "../filetree/slice.rkt"))
(check-true (impl-require? "../core/panel/model.rkt"))
(check-true (impl-require? "../core/projection/geometry.rkt"))
(check-true (impl-require? "../core/command/table.rkt"))
(check-true (impl-require? "../core/resource/model.rkt"))
(check-true (impl-require? "../core/face/model.rkt"))
(check-true (impl-require? "../render/core.rkt"))
(check-true (impl-require? "../boot/loop.rkt"))
(check-true (impl-require? "../app/state.rkt"))
(check-false (impl-require? "../core/layout/api.rkt"))
(check-false (impl-require? "../core/panel/api.rkt"))
(check-false (impl-require? "../main.rkt"))
(check-false (impl-require? "core/skeleton.rkt"))
(check-false (impl-require? "../core/skeleton.rkt"))
(check-false (impl-require? "../../core/view/panel.rkt"))
(check-false (impl-require? "../config/layout/default.rkt"))

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
