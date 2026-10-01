#lang racket

;;; ============================================================================
;;; buffer.rkt —— 编辑格组件：把一个 core 视图当可编辑文档
;;; ============================================================================
;;;
;;; 它是「一个普通可编辑文档」的组件实现：
;;;   · 没有 sync —— 它的文档就是用户编辑的文档，不需要投影；
;;;   · input / pointer 把按键翻译成 core 的**就地命令**（编辑 / 光标 / 视口）；
;;;   · 需要动全局结构的动作（保存 / 关文档）表达成 effect，交给 state.rkt。
;;;
;;; 组件不认识 tree / status / command，只依赖 state 的 ctx 语言。

(require "../core/editor.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/selection.rkt"
         "state.rkt"
         "input.rkt")

(provide buffer-input buffer-pointer)

(define (plain? k) (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))
(define (ctrl? k c) (and (key-ctrl? k) (not (key-alt? k)) (not (key-meta? k)) (eqv? (key-name k) c)))

(define (buf-do ctx f) (f (ctx-editor ctx) (ctx-vid ctx)))

(define (buf-key ctx state k)
  (define n (key-name k))
  (define ext (key-shift? k))
  (cond
    [(and (plain? k) (char? n)) (buf-do ctx (lambda (e v) (editor-view-insert! e v (string n)))) (values state '())]
    [(and (plain? k) (eq? n 'enter)) (buf-do ctx (lambda (e v) (editor-view-insert! e v "\n"))) (values state '())]
    [(and (plain? k) (eq? n 'tab)) (buf-do ctx (lambda (e v) (editor-view-insert! e v "    "))) (values state '())]
    [(and (plain? k) (eq? n 'backspace)) (buf-do ctx (lambda (e v) (editor-view-backspace! e v 'backspace))) (values state '())]
    [(and (plain? k) (memq n '(del delete))) (buf-do ctx (lambda (e v) (editor-view-delete! e v 'delete))) (values state '())]
    [(and (plain? k) (eq? n 'left)) (buf-do ctx (lambda (e v) (editor-view-left! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'right)) (buf-do ctx (lambda (e v) (editor-view-right! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'up)) (buf-do ctx (lambda (e v) (editor-view-up! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'down)) (buf-do ctx (lambda (e v) (editor-view-down! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'home)) (buf-do ctx (lambda (e v) (editor-view-home! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'end)) (buf-do ctx (lambda (e v) (editor-view-end! e v ext))) (values state '())]
    [(and (plain? k) (eq? n 'pageup)) (buf-do ctx (lambda (e v) (editor-view-scroll! e v (- (editor-view-height e v))))) (values state '())]
    [(and (plain? k) (eq? n 'pagedown)) (buf-do ctx (lambda (e v) (editor-view-scroll! e v (editor-view-height e v)))) (values state '())]
    [(ctrl? k #\z) (buf-do ctx (lambda (e v) (editor-view-undo! e v))) (values state '())]
    [(ctrl? k #\y) (buf-do ctx (lambda (e v) (editor-view-redo! e v))) (values state '())]
    [(ctrl? k #\c) (buf-do ctx (lambda (e v) (editor-view-copy! e v))) (values state '())]
    [(ctrl? k #\v) (buf-do ctx (lambda (e v) (editor-view-paste! e v))) (values state '())]
    [(ctrl? k #\s) (values state (list (list 'save (ctx-pid ctx))))]
    [(ctrl? k #\w) (values state (list (list 'close-document (editor-view-document-id (ctx-editor ctx) (ctx-vid ctx)))))]
    [else (values state '())]))

(define (buffer-input ctx state in)
  (cond
    [(text? in) (buf-do ctx (lambda (e v) (editor-view-insert! e v (text-s in)))) (values state '())]
    [(key? in) (buf-key ctx state in)]
    [else (values state '())]))

;; 鼠标：press 定位；move 从 core 选区里的锚点扩选；scroll 滚动。
(define (buffer-pointer ctx state in lr lc)
  (define ed (ctx-editor ctx))
  (define vid (ctx-vid ctx))
  (case (pointer-action in)
    [(scroll) (buf-do ctx (lambda (e v) (editor-view-scroll! e v (if (eq? (pointer-button in) 'up) -3 3))))
              (values state '())]
    [else
     (define-values (line col) (editor-view-screen-pos->point ed vid lr lc))
     (cond
       [(not line) (values state '())]
       [(eq? (pointer-action in) 'press)
        (editor-view-set-point! ed vid (point line col))
        (values state '())]
       [(eq? (pointer-action in) 'move)
        (define prim (selections-primary (editor-view-selections ed vid)))
        (define anchor (selection-anchor prim))
        (editor-view-set-selections! ed vid (selections-one (selection anchor (point line col))))
        (values state '())]
       [else (values state '())])]))

;;; ============================================================================
;;; 测试（直接喂 ctx）
;;; ============================================================================

(module+ test
  (require rackunit)

  (define ed0 (editor-open "" 20 5 #:line-numbers? #t))
  (define C (ctx 0 0 20 5 ed0 0 0 0 (list 0) (list 0) (hash) #f #f))
  (define (feed in) (define-values (st e) (buffer-input C #f in)) (values st e))
  (define (feed! in) (define-values (_st _e) (buffer-input C #f in)) (void))

  ;; 打字 / 回车 / 退格
  (feed! (key #\a #f #f #f #f))
  (feed! (text "bc"))
  (check-equal? (editor-view-string ed0 0) "abc")
  (feed! (key 'enter #f #f #f #f))
  (feed! (key #\d #f #f #f #f))
  (check-equal? (editor-view-string ed0 0) "abc\nd")
  (feed! (key 'backspace #f #f #f #f))
  (check-equal? (editor-view-string ed0 0) "abc\n")

  ;; Ctrl-S → save effect；Ctrl-W → close-document effect
  (define-values (_s1 e1) (feed (key #\s #t #f #f #f)))
  (check-equal? e1 (list (list 'save 0)))
  (define-values (_s2 e2) (feed (key #\w #t #f #f #f)))
  (check-equal? e2 (list (list 'close-document 0)))
  ;; 普通字符不动全局结构
  (define-values (_s3 e3) (feed (key #\x #f #f #f #f)))
  (check-equal? e3 '())

  (displayln "lab/buffer.rkt: all tests passed"))
