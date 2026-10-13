#lang racket

;;; edit3/plugins/auto-pair.rkt —— 括号自动配对（编辑行为插件，移植自 edit/plugins/edit/auto-pair.rkt）
;;;
;;; 只拦「editor 作用域的文本输入」，接管后自己决定：
;;;   1) 输入左括号 ( { [  → 成对插入，光标停在中间；有选区时不配对（保持“替换选区”语义）；
;;;   2) 输入右括号 ) } ]  → 若光标右边已经是同一个右括号，则**跳过**它（不重复插入）；
;;;   3) 其它文本 → 原样插入（等价于基础 insert-event-text）。
;;;
;;; 插件键表排在基础键表之前，所以 `(text) editor` 会先命中本插件；这里必须把
;;; 「非括号文本」也一起插入，否则会吞掉普通输入。

(require racket/string
         "../core/extension.rkt")

(provide auto-pair-spec)

;; 配对表：想只留 {} [] 就删掉 ( 那一项；想加别的（如 < >、" "）同理。
(define pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\])))
(define open->close (for/hash ([p (in-list pairs)]) (values (car p) (cdr p))))
(define close->open (for/hash ([p (in-list pairs)]) (values (cdr p) (car p))))

;; 当前行文本（越界 → ""）。
(define (line-text st vid)
  (define ed (state-ed st))
  (define lines (string-split (view-string ed vid) "\n"))
  (define ln (view-line ed vid))
  (if (< ln (length lines)) (list-ref lines ln) ""))

;; 光标右邻字符（行内；到行尾 / 越界 → #f）。
(define (char-after-cursor st vid)
  (define s (line-text st vid))
  (define c (view-col (state-ed st) vid))
  (and (< c (string-length s)) (string-ref s c)))

(define (pair-insert _ctx st ev _args)
  (define text (text-event-text ev))
  (cond
    [(not (= 1 (string-length text))) (insert-text st text)]
    [else
     (define ch (string-ref text 0))
     (define vid (focused-vid st))
     (cond
       [(not vid) (insert-text st text)]
       [(and (hash-has-key? open->close ch) (view-selection-empty? (state-ed st) vid))
        (define ed (state-ed st))
        (define both (string ch (hash-ref open->close ch)))
        (insert! ed vid both)
        (set-point! ed vid (view-line ed vid) (max 0 (sub1 (view-col ed vid))))
        (values (emit st 'after-insert (list vid both)) '())]
       [(and (hash-has-key? close->open ch) (view-selection-empty? (state-ed st) vid)
             (eqv? (char-after-cursor st vid) ch))
        (define ed (state-ed st))
        (set-point! ed vid (view-line ed vid) (add1 (view-col ed vid)))
        (values (emit st 'after-nav (list vid)) '())]
       [else (insert-text st text)])]))

(define auto-pair-spec
  (make-plugin
   #:name 'auto-pair
   #:ops (list (cons 'auto-pair-insert pair-insert))
   #:key-tables (list '(((text) editor (auto-pair-insert))))))
