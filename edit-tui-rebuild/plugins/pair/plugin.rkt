#lang racket

;;; edit-tui-rebuild/plugins/pair/plugin.rkt —— 括号自动配对
;;;
;;; 这是第一个正式使用扩展点的插件：
;;;   before-insert  transform：输入开符号时同时插入闭符号，并把光标左移一格
;;;   before-delete  transform：光标在两个空配对中间时，一次删掉一对
;;;
;;; 插件不碰 engine，只通过 editor/api.rkt 的查询 + edit-context 变换完成工作。

(require racket/string
         "../../editor/api.rkt")

(provide pair-plugin)

(define (pair-close-char c)
  (case c
    [(#\() #\)]
    [(#\[) #\]]
    [(#\{) #\}]
    [(#\") #\"]
    [else #f]))

(define (pair-open-char? c)
  (and (pair-close-char c) #t))

(define (line-text-at ctx)
  (define engine (edit-context-engine ctx))
  (define vid (edit-context-view-id ctx))
  (define text (engine-view-text engine vid))
  (and text
       (let ([lines (string-split text "\n" #:trim? #f)])
         (define line (point-line (edit-context-point ctx)))
         (and (< line (length lines)) (list-ref lines line)))))

(define (before-insert ctx ps)
  (define text (edit-context-text ctx))
  (cond
    [(and text (= 1 (string-length text))
          (pair-open-char? (string-ref text 0)))
     (define open (string-ref text 0))
     (define close (pair-close-char open))
     (values (struct-copy edit-context ctx
                          [text (string-append text (string close))]
                          [caret-delta -1])
             ps '() #t)]
    [else (values ctx ps '() #t)]))

(define (before-delete ctx ps)
  (define kind (edit-context-kind ctx))
  (define pt (edit-context-point ctx))
  (define line (line-text-at ctx))
  (define col (point-column pt))
  (cond
    [(not line) (values ctx ps '() #t)]
    [else
     (define at-left (and (positive? col) (<= col (string-length line))
                          (string-ref line (sub1 col))))
     (define at-right (and (< col (string-length line))
                           (string-ref line col)))
     (cond
       ;; Backspace：光标左边是开符号，右边是配对闭符号。
       [(and (eq? kind 'backspace)
             at-left at-right
             (pair-open-char? at-left)
             (eqv? (pair-close-char at-left) at-right))
        (values (struct-copy edit-context ctx
                             [delete-plan (list 'backspace 'delete)])
                ps '() #t)]
       ;; Delete：光标右边是开符号，再右边是配对闭符号。
       [(and (eq? kind 'delete)
             at-right
             (< (add1 col) (string-length line))
             (pair-open-char? at-right)
             (eqv? (pair-close-char at-right)
                   (string-ref line (add1 col))))
        (values (struct-copy edit-context ctx
                             [delete-plan (list 'delete 'delete)])
                ps '() #t)]
       [else (values ctx ps '() #t)])]))

(define pair-plugin
  (make-plugin
   #:id 'pair
   #:state #t
   #:hooks
   (list
    (make-hook #:owner 'pair
               #:id 'auto-pair
               #:operation 'insert
               #:phase 'transform
               #:priority 10
               #:fn before-insert)
    (make-hook #:owner 'pair
               #:id 'delete-pair
               #:operation 'delete
               #:phase 'transform
               #:priority 10
               #:fn before-delete))))
