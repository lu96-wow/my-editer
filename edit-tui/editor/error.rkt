#lang racket

;;; edit-tui/editor/error.rkt —— 核心 error log
;;;
;;; 这里只保存纯数据：时间、severity、来源、owner、context、message。
;;; 不保存 exn 对象 / continuation / 线程 / 文件句柄。
;;;
;;; errors 存在 editor-session，最新在前；超出上限丢最旧。
;;; 渲染成 error buffer 的 lines / faces 是纯函数，host 只负责写 UI view。

(require racket/date
         racket/list
         racket/string
         "state.rkt")

(provide (struct-out editor-error)
         error-max-entries
         state-record-error
         state-record-exception
         state-clear-errors
         errors->lines+faces)

(struct editor-error
  (time        ; seconds
   severity    ; 'error | 'warning
   source      ; 'plugin | 'hook | 'command | 'job | 'io
   owner       ; plugin-id | #f
   context     ; 任意可打印的纯数据
   message)    ; string
  #:transparent)

(define error-max-entries 500)
(define max-message-chars 4000)

(define (trim-message s)
  (cond
    [(not (string? s)) (format "~a" s)]
    [(> (string-length s) max-message-chars)
     (string-append (substring s 0 max-message-chars) "…")]
    [else s]))

(define (check-severity who severity)
  (unless (memq severity '(error warning))
    (raise-argument-error who "(or/c 'error 'warning)" severity)))

(define (state-record-error state severity source owner context message
                            #:time [time (current-seconds)])
  (check-severity 'state-record-error severity)
  (define e
    (editor-error time severity source owner context
                  (trim-message (if (and (string? message)
                                         (string=? message ""))
                                    "(no message)"
                                    message))))
  (define errors (cons e (state-errors state)))
  (define errors*
    (if (> (length errors) error-max-entries)
        (take errors error-max-entries)
        errors))
  (state-with-errors state errors*))

(define (state-record-exception state severity source owner context e
                                #:time [time (current-seconds)])
  (state-record-error state severity source owner context
                      (exn-message e)
                      #:time time))

(define (state-clear-errors state)
  (if (null? (state-errors state))
      state
      (state-with-errors state '())))

;;; ════════════════ 渲染 ════════════════

(define (error-time-string seconds)
  (date->string (seconds->date seconds #f) "~H:~M:~S"))

(define (context-string context)
  (cond
    [(not context) ""]
    [(list? context)
     (string-join (map (λ (x) (format "~a" x)) context) " ")]
    [else (format "~a" context)]))

(define (severity-tag severity)
  (case severity
    [(error) "ERROR"]
    [(warning) "WARN"]
    [else (string-upcase (symbol->string severity))]))

(define (severity-face severity)
  (case severity
    [(warning) 'error-warning]
    [else 'error-error]))

(define (error->lines e)
  (define prefix
    (string-join
     (filter values
             (list (error-time-string (editor-error-time e))
                   (format "[~a]" (severity-tag (editor-error-severity e)))
                   (format "~a" (editor-error-source e))
                   (and (editor-error-owner e)
                        (format "~a" (editor-error-owner e)))
                   (let ([c (context-string (editor-error-context e))])
                     (and (not (string=? c "")) c))))
     " "))
  (define message (editor-error-message e))
  (define msg-lines (string-split message "\n" #:trim? #f))
  (define face (severity-face (editor-error-severity e)))
  (cond
    [(null? msg-lines)
     (list (cons (format "~a: (no message)" prefix) face))]
    [else
     (cons (cons (format "~a: ~a" prefix (car msg-lines)) face)
           (for/list ([line (in-list (cdr msg-lines))])
             (cons (string-append "    " line) face)))]))

(define (errors->lines+faces errors)
  (cond
    [(null? errors)
     (values (list "(no errors)") (list 'error-empty))]
    [else
     (define rendered (append* (for/list ([e (in-list (reverse errors))])
                                 (error->lines e))))
     (values (map car rendered) (map cdr rendered))]))
