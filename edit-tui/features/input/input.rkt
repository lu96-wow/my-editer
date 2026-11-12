#lang racket

;;; edit-tui/features/input/input.rkt —— 单行输入栏（状态 / 编辑 / 投影）
;;;
;;; 输入栏是 status panel 的第二个 view。
;;; prefix 完整写进 buffer，并标记 readonly + input-prompt face；
;;; 光标可以走进 prefix 查看，但编辑只作用于 prefix 之后的文本。

(require racket/string
         "../../core/command/api.rkt"
         "../../core/layout/api.rkt"
         "../../editor/api.rkt")

(provide (struct-out input-state)
         make-input-state
         editor-input-active?
         editor-input-open
         editor-input-close
         editor-input-cancel
         editor-input-sync!
         editor-input-kind
         editor-input-text
         editor-input-prompt
         editor-input-insert
         editor-input-backspace
         editor-input-delete
         editor-input-left
         editor-input-right
         editor-input-home
         editor-input-end
         editor-input-self-insert
         editor-input-paste!)

(struct input-state
  (active?
   panel-id
   status-view
   input-view
   kind
   prompt
   text
   cursor       ; 相对可编辑文本（0 .. text 长度）
   prev-focus
   context)     ; 宿主 / prompt 使用的任意纯数据
  #:transparent)

(define (make-input-state #:panel-id panel-id
                          #:status-view status-view
                          #:input-view input-view)
  (input-state #f panel-id status-view input-view #f "" "" 0 #f #f))

(define (input-state-of state)
  (state-input state))

(define (set-input-state state s)
  (state-with-input state s))

(define (editor-input-active? state)
  (define s (input-state-of state))
  (and s (input-state-active? s)))

(define (editor-input-kind state)
  (define s (input-state-of state))
  (and s (input-state-kind s)))

(define (editor-input-text state)
  (define s (input-state-of state))
  (and s (input-state-text s)))

(define (editor-input-prompt state)
  (define s (input-state-of state))
  (and s (input-state-prompt s)))

(define (switch-view state view-id)
  (define s (input-state-of state))
  (define-values (l ok?)
    (layout-panel-set-active-view (state-layout state)
                                  (input-state-panel-id s)
                                  view-id))
  (if ok? (state-with-layout state l) state))

(define (editor-input-open state kind prompt context
                           #:text [text ""])
  (define s (input-state-of state))
  (cond
    [(not s) state]
    [else
     (define prev (or (input-state-prev-focus s)
                      (editor-focus-panel-id state)))
     (define s* (struct-copy input-state s
                             [active? #t]
                             [kind kind]
                             [prompt prompt]
                             [text text]
                             [cursor (string-length text)]
                             [prev-focus prev]
                             [context context]))
     (define state1 (set-input-state (switch-view state (input-state-input-view s*)) s*))
     (state-with-layout
      (state-with-pending state1 '())
      (layout-set-focus (state-layout state1)
                        (input-state-panel-id s*)))]))

(define (editor-input-close state)
  (define s (input-state-of state))
  (cond
    [(not s) state]
    [else
     (define prev (input-state-prev-focus s))
     (define s* (struct-copy input-state s
                             [active? #f]
                             [kind #f]
                             [prompt ""]
                             [text ""]
                             [cursor 0]
                             [prev-focus #f]
                             [context #f]))
     (define state1 (set-input-state (switch-view state (input-state-status-view s*)) s*))
     (cond
       [prev (state-with-layout
              state1
              (layout-set-focus (state-layout state1) prev))]
       [else state1])]))

(define (editor-input-cancel state)
  (values (state-with-flash (editor-input-close state) "input cancelled")
          '()))

(define (prefix-length state)
  (string-length (or (editor-input-prompt state) "")))

(define (editor-input-sync! ed state)
  (define s (input-state-of state))
  (cond
    [(not (and s (input-state-active? s))) state]
    [else
     (define prefix (input-state-prompt s))
     (define text (string-append prefix (input-state-text s)))
     (define cursor (+ (string-length prefix)
                       (max 0 (min (input-state-cursor s)
                                   (string-length (input-state-text s))))))
     (editor-set-view-content! ed
                              (input-state-input-view s)
                              (list text)
                              (list 'input)
                              #:readonly-prefix (string-length prefix)
                              #:prefix-face 'input-prompt)
     (editor-set-view-cursor! ed
                              (input-state-input-view s)
                              0 #:column cursor)
     state]))

(define (set-text state text cursor)
  (define s (input-state-of state))
  (set-input-state state (struct-copy input-state s [text text] [cursor cursor])))

(define (editor-input-insert state str)
  (define s (input-state-of state))
  (cond
    [(not (and s (input-state-active? s))) (values state '())]
    [else
     (define i (max 0 (min (input-state-cursor s) (string-length (input-state-text s)))))
     (define t (input-state-text s))
     (define text* (string-append (substring t 0 i) str (substring t i)))
     (values (set-text state text* (+ i (string-length str))) '())]))

(define (editor-input-backspace state)
  (define s (input-state-of state))
  (cond
    [(not (and s (input-state-active? s))) (values state '())]
    [else
     (define i (input-state-cursor s))
     (define t (input-state-text s))
     (cond
       [(<= i 0) (values state '())]
       [else
        (define text* (string-append (substring t 0 (sub1 i)) (substring t i)))
        (values (set-text state text* (sub1 i)) '())])]))

(define (editor-input-delete state)
  (define s (input-state-of state))
  (cond
    [(not (and s (input-state-active? s))) (values state '())]
    [else
     (define i (input-state-cursor s))
     (define t (input-state-text s))
     (cond
       [(>= i (string-length t)) (values state '())]
       [else
        (define text* (string-append (substring t 0 i) (substring t (add1 i))))
        (values (set-text state text* i) '())])]))

(define (editor-input-left state)
  (define s (input-state-of state))
  (if (and s (input-state-active? s))
      (values (set-text state (input-state-text s) (max 0 (sub1 (input-state-cursor s)))) '())
      (values state '())))

(define (editor-input-right state)
  (define s (input-state-of state))
  (if (and s (input-state-active? s))
      (values (set-text state (input-state-text s)
                        (min (string-length (input-state-text s))
                             (add1 (input-state-cursor s)))) '())
      (values state '())))

(define (editor-input-home state)
  (define s (input-state-of state))
  (if (and s (input-state-active? s))
      (values (set-text state (input-state-text s) 0) '())
      (values state '())))

(define (editor-input-end state)
  (define s (input-state-of state))
  (if (and s (input-state-active? s))
      (values (set-text state (input-state-text s) (string-length (input-state-text s))) '())
      (values state '())))

(define (printable-string s)
  (list->string
   (for/list ([c (in-string s)]
              #:when (or (char-graphic? c) (char=? c #\space)))
     c)))

(define (editor-input-self-insert state tok)
  (define text (key-text tok))
  (if text
      (editor-input-insert state text)
      (values state '())))

(define (editor-input-paste! state bytes)
  (define s (bytes->string/utf-8 bytes (integer->char 65533)))
  (editor-input-insert state (printable-string s)))
