#lang racket

;;; edit4/plugins/auto-pair.rkt —— 括号自动配对（编辑行为插件包）
;;;
;;; 接管 editor 作用域的文本输入：
;;;   1) 左括号 ( { [  → 成对插入，光标停在中间（有选区时不配对）；
;;;   2) 右括号 ) } ]  → 若光标右侧已是同一个右括号，则跳过它；
;;;   3) 其它文本 → 原样插入（必须接管，否则会吞掉普通输入）。
;;;
;;; 插件键表 `(text) editor` 覆盖基础键表同 slot；install 顺序保证后装优先。
;;; 无需 hook：edit4 的 face 每帧按 handle+cursor 重算，插入后自会刷新。

(provide auto-pair-plugin)

(require racket/string
         "../plugin.rkt"
         "../core/event.rkt" "../core/command.rkt" "../core/keymap.rkt" "../core/world.rkt"
         "../content/model.rkt" "../content/adapter.rkt")

(define pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\])))
(define open->close (for/hash ([p (in-list pairs)]) (values (car p) (cdr p))))
(define close->open (for/hash ([p (in-list pairs)]) (values (cdr p) (car p))))

(define (focused-vid w)
  (define c (world-content w))
  (and c (content-vid-of c (world-focus w))))

(define (line-text ed v)
  (define lines (string-split (view-string ed v) "\n"))
  (define ln (view-line ed v))
  (if (< ln (length lines)) (list-ref lines ln) ""))

(define (char-after-cursor ed v)
  (define s (line-text ed v))
  (define c (view-col ed v))
  (and (< c (string-length s)) (string-ref s c)))

(define (insert-text world v text)
  (insert! (content-ed (world-content world)) v text)
  (cons (emit! world 'after-insert (list v text)) '()))

(define (h-auto-pair-insert ctx world _args)
  (define v (focused-vid world))
  (cond
    [(not v) #f]
    [else
     (define text (text-event-text (ctx-event ctx)))
     (cond
       [(not (= 1 (string-length text))) (insert-text world v text)]
       [else
        (define ch (string-ref text 0))
        (define ed (content-ed (world-content world)))
        (cond
          [(and (hash-has-key? open->close ch) (view-selection-empty? ed v))
           (define both (string ch (hash-ref open->close ch)))
           (insert! ed v both)
           (set-point! ed v (view-line ed v) (max 0 (sub1 (view-col ed v))))
           (cons (emit! world 'after-insert (list v both)) '())]
          [(and (hash-has-key? close->open ch) (view-selection-empty? ed v)
                (eqv? (char-after-cursor ed v) ch))
           (nav! ed v 'right #f)
           (cons (emit! world 'after-nav (list v)) '())]
          [else (insert-text world v text)])])]))

(define auto-pair-commands
  (make-command-registry (list (cons 'auto-pair-insert h-auto-pair-insert))))

(define auto-pair-plugin
  (make-plugin
   #:name 'auto-pair
   #:commands auto-pair-commands
   #:keymap (list (list '(text) 'editor (cmd 'auto-pair-insert)))))
