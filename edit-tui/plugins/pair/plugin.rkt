#lang racket

;;; edit-tui/plugins/pair/plugin.rkt —— 括号自动配对
;;;
;;; 这是第一个正式使用扩展点的插件：
;;;   before-insert  transform：输入开符号时同时插入闭符号，并把光标左移一格；
;;;                              输入已有闭符号时跳过它，不重复插入
;;;   before-delete  transform：光标在两个空配对中间时，一次删掉一对
;;;
;;; 插件不碰 engine，只通过 editor/api.rkt 的查询 + edit-context 变换完成工作。
;;; 配对表按 mode 分开：C 额外支持字符字面量 '...'，以及 #include <>。
;;; 注意：C 的 < > 是运算符，只在 #include 指令里自动配对。

(require racket/string
         "../../editor/api.rkt")

(provide pair-plugin)

;; mode -> alist open . close
(define pair-specs
  (hash
   'racket
   (list (cons #\( #\))
         (cons #\[ #\])
         (cons #\{ #\})
         (cons #\" #\"))
   'c
   (list (cons #\( #\))
         (cons #\[ #\])
         (cons #\{ #\})
         (cons #\" #\")
         (cons #\' #\'))))

(define (code-mode ctx)
  (define ed (edit-context-editor ctx))
  (define state (edit-context-state ctx))
  (define vid (edit-context-view-id ctx))
  (define did (editor-view-doc-id ed vid))
  (define mode (and did (state-doc-mode state did)))
  (and (memq mode '(racket c)) mode))

(define (pair-specs-for mode)
  (or (hash-ref pair-specs mode #f) '()))

(define (pair-close-char mode c)
  (define p (assv c (pair-specs-for mode)))
  (and p (cdr p)))

(define (pair-open-char? mode c)
  (and (pair-close-char mode c) #t))

(define (pair-close-char? mode c)
  (and (memv c (map cdr (pair-specs-for mode))) #t))

(define (line-text-at ctx)
  (define ed (edit-context-editor ctx))
  (define vid (edit-context-view-id ctx))
  (define text (editor-view-text ed vid))
  (and text
       (let ([lines (string-split text "\n" #:trim? #f)])
         (define line (point-line (edit-context-point ctx)))
         (and (< line (length lines)) (list-ref lines line)))))

(define (line-before-caret ctx)
  (define line (line-text-at ctx))
  (define col (point-column (edit-context-point ctx)))
  (and line
       (substring line 0 (min col (string-length line)))))

;; #include 指令检测。C 的 < > 只在 include 行里配对，避免 a < b 变成 a <> b。
(define (include-directive-line? ctx)
  (define line (line-text-at ctx))
  (and line (regexp-match? #rx"^[ \t]*#[ \t]*include([ \t]|<)" line)))

(define (include-open-context? ctx)
  (regexp-match? #rx"^[ \t]*#[ \t]*include[ \t]*$" (line-before-caret ctx)))

(define (include-angle-context? ctx)
  (regexp-match? #rx"^[ \t]*#[ \t]*include[ \t]*<[^>]*$"
                 (line-before-caret ctx)))

(define (char-after-caret ctx)
  (define line (line-text-at ctx))
  (define col (point-column (edit-context-point ctx)))
  (and line (< col (string-length line)) (string-ref line col)))

;; 光标在两个空配对中间：backspace 删左+右，delete 删右+右。
(define (empty-pair-at-caret? ctx at-left at-right)
  (and at-left at-right
       (pair-open-char? (code-mode ctx) at-left)
       (eqv? (pair-close-char (code-mode ctx) at-left) at-right)))

(define (before-insert ctx ps)
  (define text (edit-context-text ctx))
  (define mode (code-mode ctx))
  (cond
    [(or (not mode)
         (not text)
         (not (= 1 (string-length text))))
     (values ctx ps '() #t)]
    [else
     (define c (string-ref text 0))
     (cond
       ;; C 的 < > 只在 #include 指令里配对。
       [(and (eq? mode 'c)
             (char=? c #\<)
             (include-open-context? ctx))
        (if (eqv? (char-after-caret ctx) #\>)
            (values (struct-copy edit-context ctx [text text] [caret-delta 0])
                    ps '() #t)
            (values (struct-copy edit-context ctx
                                 [text "<>"]
                                 [caret-delta -1])
                    ps '() #t))]
       [(and (eq? mode 'c)
             (char=? c #\>)
             (include-angle-context? ctx)
             (eqv? (char-after-caret ctx) #\>))
        (values (struct-copy edit-context ctx [text ""] [caret-delta 1])
                ps '() #t)]
       ;; 再处理闭符号跳过：输入 " / ' / ) / ] / } 时，如果右边已经是同一个
       ;; 闭符号，就把光标移过去，而不是再插一个。
       [(and (pair-close-char? mode c)
             (eqv? (char-after-caret ctx) c))
        (values (struct-copy edit-context ctx
                             [text ""]
                             [caret-delta 1])
                ps '() #t)]
       [(pair-open-char? mode c)
        (define close (pair-close-char mode c))
        ;; 右边已经是配对的闭符号时不再补一个，避免 ( 在 ) 前变成 ())。
        (if (eqv? (char-after-caret ctx) close)
            (values (struct-copy edit-context ctx [text text] [caret-delta 0])
                    ps '() #t)
            (values (struct-copy edit-context ctx
                                 [text (string-append text (string close))]
                                 [caret-delta -1])
                    ps '() #t))]
       [else (values ctx ps '() #t)])]))

(define (before-delete ctx ps)
  (define kind (edit-context-kind ctx))
  (define mode (code-mode ctx))
  (define pt (edit-context-point ctx))
  (define line (and mode (line-text-at ctx)))
  (define col (point-column pt))
  (cond
    [(not line) (values ctx ps '() #t)]
    [else
     (define at-left (and (positive? col) (<= col (string-length line))
                          (string-ref line (sub1 col))))
     (define at-right (and (< col (string-length line))
                           (string-ref line col)))
     (cond
       ;; #include <> 的空配对：只在 include 指令行里删。
       [(and (eq? mode 'c)
             (eq? kind 'backspace)
             (include-directive-line? ctx)
             (eqv? at-left #\<)
             (eqv? at-right #\>))
        (values (struct-copy edit-context ctx
                             [delete-plan (list 'backspace 'delete)])
                ps '() #t)]
       [(and (eq? mode 'c)
             (eq? kind 'delete)
             (include-directive-line? ctx)
             (eqv? at-right #\<)
             (< (add1 col) (string-length line))
             (eqv? (string-ref line (add1 col)) #\>))
        (values (struct-copy edit-context ctx
                             [delete-plan (list 'delete 'delete)])
                ps '() #t)]
       ;; Backspace：光标左边是开符号，右边是配对闭符号。
       [(and (eq? kind 'backspace)
             (empty-pair-at-caret? ctx at-left at-right))
        (values (struct-copy edit-context ctx
                             [delete-plan (list 'backspace 'delete)])
                ps '() #t)]
       ;; Delete：光标右边是开符号，再右边是配对闭符号。
       [(and (eq? kind 'delete)
             at-right
             (< (add1 col) (string-length line))
             (pair-open-char? mode at-right)
             (eqv? (pair-close-char mode at-right)
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
