#lang racket

(require "analysis.rkt" "protocol.rkt" rackunit)

;;; server.rkt —— 请求分派 + stdio 循环
;;;
;;; 方法：
;;;   analyze  (src)              → (诊断 定义清单)
;;;   complete (src line col pre) → (listof string)
;;;
;;; handle-request 是纯函数（可单测）；serve 是机械循环（读 → 分派 → 写）。

(provide handle-request serve)

;; 请求：(request <id> <method> <param> ...) → (response <id> <result>) | (error <id> <msg>)
(define (handle-request req)
  (match req
    [(list 'request id method params ...)
     (with-handlers
         ([exn:fail? (lambda (e) (list 'error id (exn-message e)))])
       (list 'response id (dispatch method params)))]
    [_ (list 'error #f "bad request: expected (request id method params...)")]))

(define (dispatch method params)
  (case method
    [(analyze)
     (match-define (list src) params)
     (list (map diag->list (module-diagnostics src))
           (module-definitions src))]
    [(complete)
     (match-define (list src line col prefix) params)
     (complete src line col prefix)]
    [else (error 'langserver "未知方法: ~a" method)]))

;; 诊断在分析层是 struct，跨进程时序列化成纯 S 表达式（非 JSON）
(define (diag->list d)
  (list (diagnostic-line d) (diagnostic-col d)
        (diagnostic-end-line d) (diagnostic-end-col d)
        (diagnostic-severity d) (diagnostic-message d)))

(define (serve in out)
  (let loop ()
    (define req (read-msg in))
    (unless (eof-object? req)
      (write-msg out (handle-request req))
      (loop))))

(module+ test
  (define src "(module t racket/base\n  (define x 1)\n)\n")

  ;; analyze：返回 (诊断 定义)
  (define resp (handle-request (list 'request 1 'analyze src)))
  (match-define (list 'response 1 (list diags defs)) resp)
  (check-equal? diags '())
  (check-equal? (map car defs) '(x))
  (check-equal? (map cadr defs) '(1))

  ;; complete
  (define resp2 (handle-request (list 'request 2 'complete src 0 0 "x")))
  (match-define (list 'response 2 names) resp2)
  (check-not-false (member "x" names))

  ;; 未知方法 → error
  (define resp3 (handle-request (list 'request 3 'nope)))
  (match-define (list 'error 3 _msg) resp3)
  (check-true (string? _msg))

  ;; 坏请求 → error
  (match-define (list 'error #f _m2) (handle-request '(garbage)))
  (check-true (string? _m2))

  (displayln "server.rkt: all tests passed"))
