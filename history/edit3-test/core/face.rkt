#lang racket

;;; edit3-test/face.rkt —— face 端口 / 分层 / 插件协议（语法高亮）+ 生命周期钩子

(require rackunit racket/list racket/file
         "../../edit3/core/extension.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/adapter.rkt"
         "../../edit3/core/face.rkt"
         "../../edit3/plugins/syntax.rkt"
         "../../edit3/plugins/words.rkt"
         "../../edit3/plugins/brackets.rkt")

(define (run1 st ev) (call-with-values (lambda () (step st (cons 80 24) ev)) (lambda (s e) s)))

;;; ---------- face 分层（纯） ----------

;; 只匹配 .rkt
(check-true (racket-file? "a.rkt"))
(check-true (racket-file? "a.rktl"))
(check-false (racket-file? "a.txt"))
(check-false (racket-file? #f))

(check-equal? (face-layers (face-compose 'a 'b)) '(a b))
(check-equal? (face-compose (face-compose 'a 'b) 'c) (face-stack '(a b c)))
(check-equal? (face-compose #f 'a) 'a)
(check-equal? (face-compose 'a #f) 'a)
(check-equal? (face-runs (vector #f 'x 'x #f 'y)) '((1 3 x) (4 5 y)))

;;; ---------- 语法高亮插件（face 端口 + 插件协议） ----------

(define tmp (make-temporary-file "ed3face~a.rkt"))
(display-to-file "(define x 1)\n(if x 2 3)\n#| c\n|# \"s\"\n" tmp #:exists 'truncate)
(define st (boot 80 24 #:text (file->string tmp) #:name tmp #:plugins (list syntax-spec)))
(define st2 (set-focused-path! st tmp))
(define ed (state-ed st2))
(define did (view-did ed (focused-vid st2)))
(check-equal? (document-face-at ed did 0 1) (palette-color 'keyword 0))      ; define
(check-eq? (document-face-at ed did 0 10) 'syntax-number)  ; 1
(check-eq? (document-face-at ed did 0 8) #f)               ; x
(check-equal? (document-face-at ed did 1 1) (palette-color 'keyword 1))      ; if
(check-eq? (document-face-at ed did 2 0) 'syntax-comment)  ; 块注释
(check-eq? (document-face-at ed did 3 0) 'syntax-comment)  ; 跨行块注释继续
(check-eq? (document-face-at ed did 3 4) 'syntax-string)   ; "s"
;; 编辑后重扫：行首插 ";" 让 define 落入注释
(define st3 (run1 st2 (text-event ";")))
(check-eq? (document-face-at (state-ed st3) did 0 2) 'syntax-comment)
;; 非 rkt 文件不触发
(define txt (make-temporary-file "ed3face~a.txt"))
(display-to-file "(define x 1)\n" txt #:exists 'truncate)
(define st4 (boot 80 24 #:text "(define x 1)\n" #:name txt #:plugins (list syntax-spec)))
(define st5 (set-focused-path! st4 txt))
(check-false (document-face-at (state-ed st5) (view-did (state-ed st5) (focused-vid st5)) 0 1))
(delete-file tmp) (delete-file txt)

;;; ---------- 词高亮（光标驱动） ----------

(define wtmp (make-temporary-file "ed3word~a.rkt"))
(display-to-file "foo bar foo\nbaz foo\n" wtmp #:exists 'truncate)
(define ws (boot 80 24 #:text (file->string wtmp) #:name wtmp #:plugins (list words-spec)))
(define ws2 (set-focused-path! ws wtmp))
(define wed (state-ed ws2))
(define wdid (view-did wed (focused-vid ws2)))
(set-point! wed (focused-vid ws2) 0 1)                ; 光标在 foo 里
(void (refresh-faces-vid! ws2 (focused-vid ws2)))
(check-eq? (document-face-at wed wdid 0 1) 'word-mark)
(check-eq? (document-face-at wed wdid 0 9) 'word-mark)   ; 第二个 foo
(check-false (document-face-at wed wdid 0 5))            ; bar 不上色
(delete-file wtmp)

;;; ---------- 括号匹配（光标驱动） ----------

(define btmp (make-temporary-file "ed3br~a.rkt"))
(display-to-file "(foo (bar) baz)\n" btmp #:exists 'truncate)
(define bs (boot 80 24 #:text (file->string btmp) #:name btmp #:plugins (list bracket-spec)))
(define bs2 (set-focused-path! bs btmp))
(define bed (state-ed bs2))
(define bdid (view-did bed (focused-vid bs2)))
(set-point! bed (focused-vid bs2) 0 0)                ; 光标在第一个 (
(void (refresh-faces-vid! bs2 (focused-vid bs2)))
(check-eq? (document-face-at bed bdid 0 0) 'bracket-match)
(check-eq? (document-face-at bed bdid 0 14) 'bracket-match)
(delete-file btmp)

;;; ---------- 生命周期钩子 ----------

(define hp (make-plugin
            #:name 'hooktest
            #:hooks (list (reaction* 'after-insert
                                     (lambda (s _args)
                                       (feature-set s 'hook-hit (add1 (feature-ref s 'hook-hit 0))))))))
(define hs0 (boot 80 24 #:name "*h*" #:plugins (list hp)))
(define hs1 (run1 hs0 (text-event "a")))
(check-equal? (feature-ref hs1 'hook-hit 0) 1)
(define hs2 (run1 hs1 (text-event "b")))
(check-equal? (feature-ref hs2 'hook-hit 0) 2)

;; 优先级：大的先跑（后跑的小优先级再叠）
(define order '())
(define p (make-plugin
           #:name 'order
           #:hooks (list (reaction* 'after-insert (lambda (s _) (set! order (append order '(hi))) s) #:priority 10)
                         (reaction* 'after-insert (lambda (s _) (set! order (append order '(lo))) s) #:priority 1))))
(define os (boot 80 24 #:name "*o*" #:plugins (list p)))
(define _os1 (run1 os (text-event "x")))
(check-equal? order '(hi lo))

(displayln "edit3/face.rkt: all tests passed")
