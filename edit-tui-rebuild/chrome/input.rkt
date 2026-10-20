#lang racket

;;; edit-tui-rebuild/chrome/input.rkt —— 输入栏
;;;
;;; 输入栏是普通 core view：
;;;   prompt label + input text
;;;
;;; prompt 数据来自 resource manager；输入栏只显示并提交：
;;;   Enter -> resource-submit
;;;   Esc   -> resource-cancel
;;;
;;; 输入模式下 step 直接接管按键，不查普通命令表。

(require racket/string
         "../app/state.rkt"
         "../app/event.rkt"
         "../command/api.rkt"
         "../layout/api.rkt"
         "../resource/api.rkt"
         "../runtime/engine.rkt")

(provide input-install-state
         input-active?
         input-sync!
         input-handle-key)

(struct input-state
  (panel-id status-view input-view active? text prev-focus)
  #:transparent)

(define (input-state* state)
  (hash-ref (app-state-store state) 'input #f))

(define (set-input-state state s)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'input s)]))

(define (input-active? state)
  (define s (input-state* state))
  (and s (input-state-active? s)))

(define (input-install-state state panel-id status-view input-view)
  (set-input-state state
                   (input-state panel-id status-view input-view #f "" #f)))

(define (input-open state)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (or (input-state-prev-focus s)
                      (app-state-focus-panel-id state)))
     (define-values (layout* ok?)
       (layout-panel-set-active-view (app-state-layout state)
                                     (input-state-panel-id s)
                                     (input-state-input-view s)))
     (define s1 (struct-copy input-state s
                             [active? #t]
                             [text ""]
                             [prev-focus prev]))
     (define state1 (set-input-state
                     (struct-copy app-state state
                                  [layout (if ok? layout* (app-state-layout state))])
                     s1))
     ;; 输入栏是在 status panel 里换 view：焦点 resource 变 #f
     (app-state-set-focus-panel state1 (input-state-panel-id s))]))

(define (input-close state)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define-values (layout* ok?)
       (layout-panel-set-active-view (app-state-layout state)
                                     (input-state-panel-id s)
                                     (input-state-status-view s)))
     (define prev (input-state-prev-focus s))
     (define s1 (struct-copy input-state s
                             [active? #f]
                             [text ""]
                             [prev-focus #f]))
     (define state1 (set-input-state
                     (struct-copy app-state state
                                  [layout (if ok? layout* (app-state-layout state))])
                     s1))
     (cond
       [prev (app-state-set-focus-panel state1 prev)]
       [else state1])]))

(define (input-cancel state)
  (define prompt (resource-prompt (app-state-resources state)))
  (define store*
    (if prompt
        (resource-cancel (app-state-resources state) (prompt-id prompt))
        (app-state-resources state)))
  (values (input-close (struct-copy app-state state [resources store*])) '()))

(define (prompt-text prompt text)
  (string-append (prompt-label prompt) text))

(define (input-sync! state engine)
  (define prompt (resource-prompt (app-state-resources state)))
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define state1
       (cond
         [(and prompt (not (input-state-active? s))) (input-open state)]
         [(and (not prompt) (input-state-active? s)) (input-close state)]
         [else state]))
     (define s1 (input-state* state1))
     (cond
       [s1
        (define text (if prompt (prompt-text prompt (input-state-text s1)) ""))
        (engine-set-view-lines! engine (input-state-input-view s1)
                                 (list text) (list 'input) 0
                                 #:column (string-length text))]
       [else (void)])
     state1]))

;; 输入栏和 edit 共用 key-text：'key / 'utf8 的 token -> 文本，其它 -> #f
(define (input-typed-text tok)
  (and (key? tok) (key-text tok)))

(define (tok=? a b)
  (and (key? a) (key=? a b)))

(define (input-handle-key state ev)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) #f]
    [else
     (define tok (key-event-token ev))
     (cond
       [(tok=? tok (key 'g 'ctrl))
        (input-cancel state)]
       [(tok=? tok (key 'escape))
        (input-cancel state)]
       [(tok=? tok (key 'enter))
        (define prompt (resource-prompt (app-state-resources state)))
        (cond
          [(not prompt) (values (input-close state) '())]
          [else
           (define value
             (if (eq? (prompt-kind prompt) 'confirm)
                 (string->symbol (string-trim (input-state-text s)))
                 (input-state-text s)))
           (define-values (store* actions)
             (resource-submit (app-state-resources state)
                              (prompt-id prompt) value))
           (define state1 (struct-copy app-state state [resources store*]))
           (values (input-close state1) actions)])]
       [(tok=? tok (key 'backspace))
        (define text (input-state-text s))
        (define text* (if (zero? (string-length text))
                          text
                          (substring text 0 (sub1 (string-length text)))))
        (values (set-input-state state
                                 (struct-copy input-state s [text text*]))
                '())]
       [else
        (define ch (input-typed-text tok))
        (cond
          [(not ch) (values state '())]
          [else
           (values (set-input-state state
                                    (struct-copy input-state s
                                                 [text (string-append (input-state-text s) ch)]))
                   '())])])]))
