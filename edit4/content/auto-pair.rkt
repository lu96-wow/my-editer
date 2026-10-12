#lang racket

;;; edit4/content/auto-pair.rkt —— 括号自动配对（编辑行为插件）
;;;
;;; 自包含插件：接管 editor 作用域的文本输入。
;;;   1) 输入左括号 ( { [  → 成对插入，光标停在中间（有选区时不配对，保持替换语义）；
;;;   2) 输入右括号 ) } ]  → 若光标右侧已是同一个右括号，则跳过它；
;;;   3) 其它文本 → 原样插入（必须接管，否则会吞掉普通输入）。
;;;
;;; 插件键表 `(text) editor` 覆盖基础键表同 slot；由 app.rkt 的装配顺序保证后装优先。
;;; 无需 hook：edit4 的 face 每帧按 handle+cursor 重算，插入后自会刷新。

(provide auto-pair-commands auto-pair-keymap)

(require racket/string
         "../core/event.rkt" "../core/world.rkt" "../core/command.rkt" "../core/keymap.rkt"
         "model.rkt" "adapter.rkt")

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

;; 光标右邻字符（行内；到行尾 / 越界 → #f）。
(define (char-after-cursor ed v)
  (define s (line-text ed v))
  (define c (view-col ed v))
  (and (< c (string-length s)) (string-ref s c)))

(define (insert-text world v text)
  (insert! (content-ed (world-content world)) v text)
  (cons world '()))

(define (h-auto-pair-insert ctx world _args)
  (define v (focused-vid world))
  (cond
    [(not v) #f]                                ; 非编辑器焦点 → 让位
    [else
     (define text (text-event-text (ctx-event ctx)))
     (cond
       [(not (= 1 (string-length text))) (insert-text world v text)]
       [else
        (define ch (string-ref text 0))
        (define ed (content-ed (world-content world)))
        (cond
          [(and (hash-has-key? open->close ch) (view-selection-empty? ed v))
           (insert! ed v (string ch (hash-ref open->close ch)))
           (set-point! ed v (view-line ed v) (max 0 (sub1 (view-col ed v))))
           (cons world '())]
          [(and (hash-has-key? close->open ch) (view-selection-empty? ed v)
                (eqv? (char-after-cursor ed v) ch))
           (nav! ed v 'right #f)
           (cons world '())]
          [else (insert-text world v text)])])]))

(define auto-pair-commands
  (make-command-registry (list (cons 'auto-pair-insert h-auto-pair-insert))))

(define auto-pair-keymap
  (list (list '(text) 'editor (cmd 'auto-pair-insert))))
