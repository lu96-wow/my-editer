#lang racket

;;; edit/plugins/edit/auto-pair.rkt —— 括号自动配对（编辑行为插件）
;;;
;;; 只管两件事，都作用在「直接输入」（cmd-insert 单字符）上：
;;;   1) 输入左括号 ( { [  → 成对插入，光标停在中间；
;;;      · 只在**无选区**的普通编辑视图上做（有选区时保持“替换选区”的原语义）；
;;;      · 面板 / 输入行 / 文档窗都是 dock 面，直接让原命令处理，不配对。
;;;   2) 输入右括号 ) } ]  → 若光标右边已经是同一个右括号，则**跳过**它（不重复插入）。
;;;
;;; 走 handler 链拦在 step-base 之前：命中才返回会话，其余一律 #f 让位。
;;; 插入用 session-insert（会发 after-edit / after-insert），高亮 / 补全照常联动；
;;; 光标回退 / 跳过用 session-ed-set-point!（低层，不额外发导航事件）。

(require "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt")

(provide auto-pair-spec)

;; 配对表：想只留 {} [] 就删掉 ( 那一项；想加别的（如 < >、" "）同理。
(define pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\])))
(define open->close (for/hash ([p (in-list pairs)]) (values (car p) (cdr p))))
(define close->open (for/hash ([p (in-list pairs)]) (values (cdr p) (car p))))

;; 当前焦点是不是可配对的普通编辑视图（非 dock 面）。
(define (editable-focus s)
  (define vid (session-focus-vid s))
  (and vid (not (session-dock-vid? s vid)) vid))

;; 光标右邻字符（行内；到行尾 / 越界 → #f）。
(define (char-after-cursor s vid)
  (define line (session-view-point-line s vid))
  (define col (session-view-point-column s vid))
  (define text (line-at (session-view-string s vid) line))
  (and (< col (string-length text)) (string-ref text col)))

;; 单个字符的插入：左括号 → 成对 + 回退一格；右括号且右边已是它 → 跳过。
(define (handle-insert s text)
  (cond
    [(not (= 1 (string-length text))) #f]
    [else
     (define ch (string-ref text 0))
     (cond
       [(hash-has-key? open->close ch) (maybe-pair s ch)]
       [(hash-has-key? close->open ch) (maybe-skip s ch)]
       [else #f])]))

(define (maybe-pair s open)
  (define vid (editable-focus s))
  (cond
    [(not vid) #f]
    ;; 有选区时不配对：让原始的「插入替换选区」语义生效。
    [(not (session-view-selection-empty? s vid)) #f]
    [else
     (define close (hash-ref open->close open))
     (define s1 (session-insert s (string open close)))
     (define vid* (session-focus-vid s1))
     ;; 插完光标在右括号后，回退到两括号之间。
     (define line (session-view-point-line s1 vid*))
     (define col (session-view-point-column s1 vid*))
     (session-ed-set-point! s1 vid* line (max 0 (sub1 col)))]))

(define (maybe-skip s close)
  (define vid (editable-focus s))
  (cond
    [(not vid) #f]
    [(not (session-view-selection-empty? s vid)) #f]
    [(eqv? (char-after-cursor s vid) close)
     (define line (session-view-point-line s vid))
     (define col (session-view-point-column s vid))
     (session-ed-set-point! s vid line (add1 col))]
    [else #f]))

;; 声明式命令路由（取代 auto-pair-handler）：只拦 cmd-insert，非括号则 'pass 回落到原插入。
(define (auto-pair-routes)
  (list
   (route* (command-pred cmd-insert?)
           (handler-effect
            (lambda (s cmd)
              (define r (handle-insert s (cmd-insert-text cmd)))
              (if r (values r 'handled) (values s 'pass))))
           #:when (scope-focus-kind 'editor) #:priority 10)))

(define (auto-pair-install s)
  (for/fold ([s s]) ([r (in-list (auto-pair-routes))]) (session-add-route s r)))

(define auto-pair-spec
  (plugin-spec 'auto-pair auto-pair-install '()))
