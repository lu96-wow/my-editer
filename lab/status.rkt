#lang racket

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/width.rkt"
         "host.rkt")

;;; status.rkt —— 状态栏组件（纯投影）
;;;
;;; 两种形态：
;;;   常态  投影焦点视图的 L/C/mode/undo + msg
;;;   提示  一行 label + buffer（新建文件命名等），app 改 buffer，组件只投影
;;;
;;; 它只提供两样东西：状态 status、投影 status-sync。不 require 渲染、不持有 vid、不写 editor。

(provide
 ;; ---------- 状态 ----------
 (struct-out status) status-set-msg
 ;; ---------- 提示态 ----------
 status-start-prompt status-clear-prompt
 status-prompting? status-input-buffer status-set-buffer
 ;; ---------- 投影 ----------
 status-sync)

(struct status (msg input) #:transparent)
;; input : #f | (cons label buffer)    #f = 常态；否则提示态

(define (status-set-msg s m) (struct-copy status s [msg m]))

(define (status-start-prompt s label buffer) (struct-copy status s [input (cons label buffer)]))
(define (status-clear-prompt s) (struct-copy status s [input #f]))
(define (status-prompting? s) (and (status-input s) #t))
(define (status-input-buffer s) (if (status-input s) (cdr (status-input s)) ""))
(define (status-set-buffer s buf)
  (if (status-input s) (struct-copy status s [input (cons (car (status-input s)) buf)]) s))

(define (fit-width s w)
  (define b (open-output-string))
  (define col 0)
  (for ([ch (in-string s)])
    (define cw (char-display-width ch))
    (when (<= (+ col cw) w) (display ch b) (set! col (+ col cw))))
  (string-append (get-output-string b) (make-string (max 0 (- w col)) #\space)))

;; → (values document status)
(define (status-sync ctx st)
  (values (if (status-input st) (prompt-doc st ctx) (status-doc st ctx)) st))

(define (status-doc st ctx)
  (define ed (ctx-editor ctx))
  (define vid (ctx-focus-vid ctx))
  (define w (ctx-cols ctx))
  (define txt
    (fit-width
     (cond
       [vid (format "  L~a C~a | ~a | undo ~a | ~a"
                    (editor-view-point-line ed vid)
                    (editor-view-point-col ed vid)
                    (editor-view-mode ed vid)
                    (editor-view-depth ed vid)
                    (status-msg st))]
       [else (format "  ~a" (status-msg st))])
     w))
  (document-highlight-fill (document-open txt) 0 0 0 (string-length txt) 'status))

;; 提示态：label + buffer（全宽底色）。
(define (prompt-doc st ctx)
  (define label (car (status-input st)))
  (define buf (cdr (status-input st)))
  (define txt (fit-width (string-append label buf "_") (ctx-cols ctx)))
  (document-highlight-fill (document-open txt) 0 0 0 (string-length txt) 'status))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit
           "../core/text/base/point.rkt")

  (define ed (editor-open "abc\ndef" 20 5))
  (define base (ctx ed 0 0 0 0 5 60))

  ;; 读的是**焦点视图**的 L/C，不是组件自己
  (define-values (doc _s1) (status-sync base (status "hi" #f)))
  (check-true (regexp-match? #rx"L0 C0" (document->string doc)))
  (check-true (regexp-match? #rx"hi" (document->string doc)))

  (define ed* (editor-view-set-point ed 0 (point 1 2)))
  (define-values (doc* _s2) (status-sync (ctx ed* 0 0 0 0 5 60) (status "hi" #f)))
  (check-true (regexp-match? #rx"L1 C2" (document->string doc*)))

  ;; 焦点不在任何视图 → 只显示消息
  (define-values (doc0 _s3) (status-sync (ctx ed 0 #f 0 0 5 20) (status "only-msg" #f)))
  (check-true (regexp-match? #rx"only-msg" (document->string doc0)))
  (check-false (regexp-match? #rx"undo" (document->string doc0)))

  ;; 提示态：显示 label + buffer
  (define pv (status-start-prompt (status "" #f) "新建文件: " "untitled"))
  (define-values (dp _) (status-sync (ctx ed 0 0 0 0 5 60) pv))
  (check-true (regexp-match? #rx"新建文件: untitled" (document->string dp)))
  (check-true (status-prompting? pv))
  (check-equal? (status-input-buffer (status-set-buffer pv "abc")) "abc")

  (displayln "lab/status.rkt: all tests passed"))
