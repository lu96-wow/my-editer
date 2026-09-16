#lang racket

;;; plugin-reference/auto-pair.rkt —— 示例编辑策略：括号自动配对
;;;
;;; 这是「编辑策略」（slot #2b）：window-commands -> window-commands（命令装饰器）。
;;;   - 文档标注插件（buffer→patch）改不了文本；自动配对要插入/删除括号，
;;;     所以它包装命令层，在 text/key 事件到达默认命令前先拦截处理。
;;;   - 只 (require "../plugin/edit-api.rkt")，证明编辑面契约已足够。
;;;
;;; 行为：
;;;   - 输入 ( [ { 时自动补上匹配的右括号，光标落在两者之间
;;;   - 光标夹在空括号对（如 () ）中按退格/删除时，一次删掉两个括号
;;;   - 其它输入原样交给默认命令
;;;
;;; 用法（demo.rkt）：
;;;   (define-values (wc fc) (make-default-commands))
;;;   (define ap-wc (auto-pair-strategy wc))          ; 或 (compose-edit-strategies auto-pair-strategy ...)
;;;   (make-config #:window-commands ap-wc ...)

(require "../plugin/edit-api.rkt"
         rackunit)

(provide auto-pair-strategy)

;; 括号对：左 → 右。想加别的对（如 " ' 或 < >），在这里加一行即可。
(define pairs (hash #\( #\)  #\[ #\]  #\{ #\}))

;;; ---------- 编辑策略（命令装饰器） ----------

(define (auto-pair-strategy base)
  (window-commands
   (lambda (cfg f ev) (auto-pair-on-text base cfg f ev))
   (lambda (cfg f ev) (auto-pair-on-key base cfg f ev))))

;;; ---------- text：输入左括号 → 补右括号 ----------

(define (auto-pair-on-text base cfg f ev)
  (define t (text-event-text ev))
  (define open (and (= (string-length t) 1) (string-ref t 0)))
  (if (and open (hash-has-key? pairs open))
      (auto-pair-insert cfg f open)
      ((window-commands-on-text base) cfg f ev)))

;; 插入 "()" 并把光标放到两个括号之间（走完整编辑管线：编辑插件 + 标注插件 + 同步）
(define (auto-pair-insert cfg f open)
  (define close (hash-ref pairs open))
  (edit-active cfg f
    (lambda (w)
      (define p (window-point w))
      (define l (cursor-line p))
      (define c (cursor-col p))
      (define-values (w1 d) (window-insert-text w (string open close)))
      (values (window-set-point w1 (cursor l (add1 c))) d))))

;;; ---------- key：空括号对里退格/删除 → 一次删两个 ----------

(define (auto-pair-on-key base cfg f ev)
  (define k (key-event-key ev))
  (if (memq k '(backspace delete))
      (let-values ([(handled f* d* done*) (auto-pair-delete cfg f)])
        (if handled
            (values f* d* done*)
            ((window-commands-on-key base) cfg f ev)))
      ((window-commands-on-key base) cfg f ev)))

;; 光标夹在空括号对里 → 处理并返回 (values #t frame desc done?)；否则 (values #f f #f #f)
(define (auto-pair-delete cfg f)
  (define w (frame-active-window f))
  (define p (window-point w))
  (define b (window-buffer w))
  (define l (cursor-line p))
  (define c (cursor-col p))
  (define text (buffer-line-ref b l))
  (define before (and (> c 0) (string-ref text (sub1 c))))
  (define after  (and (< c (string-length text)) (string-ref text c)))
  (if (and before after
           (hash-has-key? pairs before)
           (char=? (hash-ref pairs before) after))
      (let-values ([(f* d* done*) (edit-active cfg f auto-pair-delete-edit)])
        (values #t f* d* done*))
      (values #f f #f #f)))

;; 一次 splice 删掉 [c-1, c+1) 两个括号；光标落到删除起点
(define (auto-pair-delete-edit w)
  (define p (window-point w))
  (define l (cursor-line p))
  (define c (cursor-col p))
  (define b (window-buffer w))
  (define-values (b2 d) (buffer-splice b l (sub1 c) l (add1 c) ""))
  (values (window-set-buffer (window-set-point w (edit-desc-after-position d)) b2)
          d))

;;; ---------- 测试 ----------

(module+ test
  (require "../reference/commands.rkt"     ; make-default-commands
           "../reference/layout-tree.rkt"  ; tree-layout
           "../reference/compose-line.rkt") ; line-compose

  (define-values (wc fc) (make-default-commands))
  (define ap-wc (auto-pair-strategy wc))
  (define cfg (make-config #:window-commands ap-wc #:frame-commands fc
                           #:layout tree-layout #:compose line-compose
                           #:plugins '() #:view-plugins '() #:theme (hash)))

  ;; 输入 ( → 自动补 () 且光标在中间
  (define f0 (frame-open (buffer-open "") 3 20))
  (define-values (f1 _d1 _done1)
    ((window-commands-on-text ap-wc) cfg f0 (text-event "(" (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f1))) "()")
  (check-equal? (window-point (frame-active-window f1)) (cursor 0 1))

  ;; 空括号里退格 → 一次删两个
  (define-values (f2 _d2 _done2)
    ((window-commands-on-key ap-wc) cfg f1 (key-event 'backspace (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f2))) "")
  (check-equal? (window-point (frame-active-window f2)) (cursor 0 0))

  ;; 非空括号里退格 → 不整对删，正常退格（删掉一个字符）
  (define f3 (frame-open (buffer-open "(x)") 3 20))
  (define f4 (frame-set-window f3 0 (window-set-point (frame-window f3 0) (cursor 0 2))))
  (define-values (f5 _d5 _done5)
    ((window-commands-on-key ap-wc) cfg f4 (key-event 'backspace (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f5))) "()")

  ;; [ 和 { 同样配对
  (define-values (f6 _d6 _done6)
    ((window-commands-on-text ap-wc) cfg (frame-open (buffer-open "") 3 20)
                               (text-event "[" (modifiers #f #f #f #f))))
  (check-equal? (buffer->string (window-buffer (frame-active-window f6))) "[]")

  (displayln "auto-pair.rkt: all tests passed"))
