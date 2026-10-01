#lang racket

;;; ============================================================================
;;; buffer.rkt —— 编辑格组件：把一个 core 视图当可编辑文档
;;; ============================================================================
;;;
;;; 它是「一个普通可编辑文档」的组件实现：
;;;   · 没有 sync —— 它的文档就是用户编辑的文档，不需要投影；
;;;   · input / pointer 把中间层输入（key / text / mouse / wheel）翻译成 core 的
;;;     **就地命令**（编辑 / 光标 / 视口）；
;;;   · 需要动全局结构的动作（保存 / 关文档）表达成 effect，交给 state.rkt。
;;;
;;; 组件不认识 tree / status / command，只依赖 state 的 ctx 语言。

(require "../core/editor.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/selection.rkt"
         "state.rkt"
         "input.rkt")

(provide buffer-input buffer-pointer)

(define (plain? k)
  (let ([m (key-modifiers k)])
    (and (not (modifiers-control m)) (not (modifiers-alt m)) (not (modifiers-meta m)))))

(define (ctrl? k c)
  (let ([m (key-modifiers k)])
    (and (modifiers-control m) (not (modifiers-alt m)) (not (modifiers-meta m))
         (eqv? (key-name k) c))))

(define (buf-do ctx f) (f (ctx-editor ctx) (ctx-vid ctx)))

(define (buf-key ctx state k)
  (define n (key-name k))
  (define ext (modifiers-shift (key-modifiers k)))
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

;; 鼠标 / 滚轮：
;;   press → 定位；drag → 从锚点扩选；move → 不动（gui 的无按键移动）；
;;   wheel up/down → 滚动。
(define (buffer-pointer ctx state in lr lc)
  (define ed (ctx-editor ctx))
  (define vid (ctx-vid ctx))
  (cond
    [(wheel? in)
     (buf-do ctx (lambda (e v) (editor-view-scroll! e v (if (eq? (wheel-direction in) 'up) -3 3))))
     (values state '())]
    [(mouse? in)
     (case (mouse-kind in)
       [(press)
        (define-values (line col) (editor-view-screen-pos->point ed vid lr lc))
        (when line (editor-view-set-point! ed vid (point line col)))
        (values state '())]
       [(drag)
        (define-values (line col) (editor-view-screen-pos->point ed vid lr lc))
        (cond
          [(not line) (values state '())]
          [else
           (define prim (selections-primary (editor-view-selections ed vid)))
           (define anchor (selection-anchor prim))
           (editor-view-set-selections! ed vid (selections-one (selection anchor (point line col))))
           (values state '())])]
       [else (values state '())])]
    [else (values state '())]))

;;; ============================================================================
;;; 测试（直接喂 ctx）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/text/base/range.rkt")

  (define (k name [ctrl? #f] [alt? #f] [shift? #f])
    (key name (modifiers ctrl? alt? shift? #f)))
  (define ed0 (editor-open "" 20 5 #:line-numbers? #t))
  (define C (ctx 0 0 20 5 ed0 0 0 0 (list 0) (list 0) (hash) #f #f))
  (define (feed in) (define-values (st e) (buffer-input C #f in)) (values st e))
  (define (feed! in) (define-values (_st _e) (buffer-input C #f in)) (void))

  ;; 打字 / 回车 / 退格
  (feed! (k #\a))
  (feed! (text "bc" modifiers-none))
  (check-equal? (editor-view-string ed0 0) "abc")
  (feed! (k 'enter))
  (feed! (k #\d))
  (check-equal? (editor-view-string ed0 0) "abc\nd")
  (feed! (k 'backspace))
  (check-equal? (editor-view-string ed0 0) "abc\n")

  ;; Ctrl-S → save effect；Ctrl-W → close-document effect
  (define-values (_s1 e1) (feed (k #\s #t)))
  (check-equal? e1 (list (list 'save 0)))
  (define-values (_s2 e2) (feed (k #\w #t)))
  (check-equal? e2 (list (list 'close-document 0)))
  ;; 普通字符不动全局结构
  (define-values (_s3 e3) (feed (k #\x)))
  (check-equal? e3 '())

  ;; 鼠标：press 定位、drag 扩选、move 不动（行号栏占 2 格，局部列 −2 = 正文列）
  (define (mp! in r c) (define-values (_st _e) (buffer-pointer C #f in r c)) (void))
  (editor-view-set-point! ed0 0 (point 0 0))
  (mp! (mouse 'press 'left 0 4 modifiers-none) 0 4)
  (check-equal? (editor-view-point ed0 0) (point 0 2))
  (mp! (mouse 'drag 'left 0 2 modifiers-none) 0 2)
  (check-equal? (editor-view-primary-range ed0 0) (range-of (point 0 0) (point 0 2)))
  (mp! (mouse 'move #f 0 3 modifiers-none) 0 3)                   ; 无按键移动
  (check-equal? (editor-view-primary-range ed0 0) (range-of (point 0 0) (point 0 2)))

  (displayln "lab/buffer.rkt: all tests passed"))
