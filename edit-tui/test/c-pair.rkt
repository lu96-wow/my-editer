#lang racket

;;; C 括号配对：{} () [] "" ''、闭符号跳过、空配对删除。

(require rackunit
         racket/file
         racket/path
         "../core/api.rkt"
         "../editor/host-api.rkt"
         "../edit.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt")

(define root (make-temporary-directory))

(define (fresh-c name)
  (define path (build-path root name))
  (display-to-file "" path #:exists 'replace)
  (define-values (ed s0) (make-editor-app #:workspace-root root))
  (define s1 (state-with-screen s0 (rect 0 0 40 10)))
  (define-values (s2 _a) (editor-open-file! ed s1 path))
  (define vid (editor-placement-view-id s2))
  (define-values (s3 _b) (editor-placement-commit ed s2))
  (values ed s3 vid))

(define (text ed vid) (editor-view-text ed vid))
(define (col ed vid) (engine-view-point-column (editor-engine ed) vid))

;; 每个开符号都插入对应闭符号，光标停在中间。
(for ([pair (in-list '((#\( . #\))
                       (#\[ . #\])
                       (#\{ . #\})
                       (#\" . #\")
                       (#\' . #\'))) ]
      [i (in-naturals)])
  (define-values (ed s vid) (fresh-c (format "pair-~a.c" i)))
  (define-values (s1 _a) (editor-insert! ed s vid (string (car pair))))
  (check-equal? (text ed vid) (string (car pair) (cdr pair)))
  (check-equal? (col ed vid) 1))

;; 输入已有闭符号时跳过，不重复插入。
(define-values (ed-skip s-skip0 vid-skip) (fresh-c "skip.c"))
(define-values (s-skip1 _sa) (editor-insert! ed-skip s-skip0 vid-skip "("))
(define-values (s-skip2 _sb) (editor-insert! ed-skip s-skip1 vid-skip ")"))
(check-equal? (text ed-skip vid-skip) "()")
(check-equal? (col ed-skip vid-skip) 2)

;; 引号同样可以跳过。
(define-values (ed-q s-q0 vid-q) (fresh-c "quote.c"))
(define-values (s-q1 _qa) (editor-insert! ed-q s-q0 vid-q "\""))
(define-values (s-q2 _qb) (editor-insert! ed-q s-q1 vid-q "\""))
(check-equal? (text ed-q vid-q) "\"\"")
(check-equal? (col ed-q vid-q) 2)

;; #include <>：只在 include 行配对，输入 > 时跳过已有闭符号。
(define-values (ed-i s-i0 vid-i) (fresh-c "include.c"))
(define-values (s-i1 _ia) (editor-insert! ed-i s-i0 vid-i "#include "))
(define-values (s-i2 _ib) (editor-insert! ed-i s-i1 vid-i "<"))
(check-equal? (text ed-i vid-i) "#include <>")
(check-equal? (col ed-i vid-i) (string-length "#include <"))
(define-values (s-i3 _ic) (editor-insert! ed-i s-i2 vid-i ">"))
(check-equal? (text ed-i vid-i) "#include <>")
(check-equal? (col ed-i vid-i) (string-length "#include <>"))

;; include <> 的 Backspace / Delete 一次删一对。
(define-values (s-i4 _id)
  (editor-select! ed-i s-i3 vid-i
                  (selections-one (caret (point 0 (string-length "#include <"))))))
(define-values (s-i5 _ie) (editor-delete! ed-i s-i4 vid-i 'backspace))
(check-equal? (text ed-i vid-i) "#include ")

(define-values (ed-i2 s-i20 vid-i2) (fresh-c "include-delete.c"))
(define-values (s-i21 _i2a) (editor-insert! ed-i2 s-i20 vid-i2 "#include <>"))
(define-values (s-i22 _i2b)
  (editor-select! ed-i2 s-i21 vid-i2
                  (selections-one (caret (point 0 (string-length "#include "))))))
(define-values (s-i23 _i2c) (editor-delete! ed-i2 s-i22 vid-i2 'delete))
(check-equal? (text ed-i2 vid-i2) "#include ")

;; 普通 C 表达式里的 < > 不配对。
(define-values (ed-lt s-lt0 vid-lt) (fresh-c "less.c"))
(define-values (s-lt1 _la) (editor-insert! ed-lt s-lt0 vid-lt "a "))
(define-values (s-lt2 _lb) (editor-insert! ed-lt s-lt1 vid-lt "<"))
(check-equal? (text ed-lt vid-lt) "a <")

;; 右边已有闭符号时，输入开符号不再补一个闭符号。
(define-values (ed-n s-n0 vid-n) (fresh-c "nested.c"))
(define-values (s-n1 _na) (editor-insert! ed-n s-n0 vid-n ")"))
(define-values (s-n2 _nb)
  (editor-select! ed-n s-n1 vid-n (selections-one (caret (point 0 0)))))
(define-values (s-n3 _nc) (editor-insert! ed-n s-n2 vid-n "("))
(check-equal? (text ed-n vid-n) "()")
(check-equal? (col ed-n vid-n) 1)

;; 外层还有未闭合括号时，输入开符号补成嵌套对，而不是借用外层的闭符号。
(define-values (ed-nest s-nest0 vid-nest) (fresh-c "nested-paren.c"))
(define-values (s-nest1 _nest1) (editor-insert! ed-nest s-nest0 vid-nest "("))
(define-values (s-nest2 _nest2) (editor-insert! ed-nest s-nest1 vid-nest "define "))
(define-values (s-nest3 _nest3) (editor-insert! ed-nest s-nest2 vid-nest "("))
(check-equal? (text ed-nest vid-nest) "(define ())")
(check-equal? (col ed-nest vid-nest) 9)
(define-values (s-nest4 _nest4) (editor-insert! ed-nest s-nest3 vid-nest ")"))
(check-equal? (text ed-nest vid-nest) "(define ())")
(check-equal? (col ed-nest vid-nest) 10)
(define-values (s-nest5 _nest5) (editor-insert! ed-nest s-nest4 vid-nest ")"))
(check-equal? (text ed-nest vid-nest) "(define ())")
(check-equal? (col ed-nest vid-nest) 11)

;; 空配对中间 Backspace / Delete 一次删一对。
(define-values (ed-b s-b0 vid-b) (fresh-c "backspace.c"))
(define-values (s-b1 _ba) (editor-insert! ed-b s-b0 vid-b "("))
(define-values (s-b2 _bb) (editor-delete! ed-b s-b1 vid-b 'backspace))
(check-equal? (text ed-b vid-b) "")

(define-values (ed-d s-d0 vid-d) (fresh-c "delete.c"))
(define-values (s-d1 _da) (editor-insert! ed-d s-d0 vid-d "("))
;; Delete 的“空配对”场景：光标在开括号之前，而不是中间。
(define-values (s-d1p _dap)
  (editor-select! ed-d s-d1 vid-d
                  (selections-one (caret (point 0 0)))))
(define-values (s-d2 _db) (editor-delete! ed-d s-d1p vid-d 'delete))
(check-equal? (text ed-d vid-d) "")

;; Racket 的 quote 不是 C 字符字面量，不应该自动配对。
(define rkt-path (build-path root "quote.rkt"))
(display-to-file "" rkt-path #:exists 'replace)
(define-values (ed-r s-r0) (make-editor-app #:workspace-root root))
(define s-r1 (state-with-screen s-r0 (rect 0 0 40 10)))
(define-values (s-r2 _ra) (editor-open-file! ed-r s-r1 rkt-path))
(define r-vid (editor-placement-view-id s-r2))
(define-values (s-r3 _rb) (editor-placement-commit ed-r s-r2))
(define-values (s-r4 _rc) (editor-insert! ed-r s-r3 r-vid "'"))
(check-equal? (editor-view-text ed-r r-vid) "'")

(delete-directory/files root)
(displayln "edit-tui/test/c-pair.rkt: ok")
