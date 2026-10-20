#lang racket

;;; edit-tui-rebuild/chrome/input.rkt —— 输入栏（服务插件）
;;;
;;; 输入栏是普通 core view：一行 = prompt 前缀 + 输入文本 + 光标。
;;; 文本 / 光标归 State（input-state），每帧投影到 view；前缀 readonly。
;;;
;;; 两种输入来源：
;;;   1. resource prompt（骨架资源管理产生）：save-path / confirm
;;;   2. 插件请求：(input-start state (input-request ...))，
;;;      on-done 回调拿到 (input-result id status value)
;;;
;;; 打断 / 挤占规范（输入栏是抢占式的）：
;;;   - 输入激活时，**非 key / paste 事件**（mouse / resize / quit / internal）
;;;     先取消本次输入，再处理该事件；
;;;   - 新的插件请求挤占旧插件请求：旧请求 on-done status = 'preempted；
;;;   - 系统 prompt 优先：出现时挤占插件请求（'preempted）；
;;;   - Esc / C-g：插件请求 on-done 'cancelled；系统 prompt 走 resource-cancel。
;;;
;;; 关闭 / 取消 / 挤占都会回调 on-done（插件请求），宿主不需要轮询。

(require racket/string
         "../skeleton.rkt"
         "../app/state.rkt"
         "../app/event.rkt")

(provide input-install-state
         input-active?
         input-reconcile
         input-sync!
         input-handle-key
         input-handle-paste
         input-start
         input-interrupt
         (struct-out input-request)
         (struct-out input-result))

;;; ════════════════ 值 ════════════════

(struct input-request
  (id        ; 任意 equal? 值，回调里带回来
   label     ; prompt 前缀
   kind      ; 'text | 'confirm
   choices   ; (listof symbol)，confirm 用
   default   ; 默认文本
   on-done)  ; (state input-result -> (values state actions))
  #:transparent)

(struct input-result (id status value) #:transparent)
;; status : 'submitted | 'cancelled | 'preempted
;; value  : string（text 提交）| symbol（confirm 提交）| #f

(struct input-state
  (panel-id     ; 输入栏所在的 panel（status panel）
   status-view  ; 平时显示的 view
   input-view   ; 输入时显示的 view
   active?
   source       ; 'resource | 'plugin | #f
   request      ; input-request | #f（source = 'plugin）
   prompt-id    ; resource prompt id | #f（source = 'resource）
   text         ; 已输入文本（不含前缀）
   cursor       ; 文本内光标（0..string-length）
   prev-focus)  ; 打开输入栏前的焦点 panel，关闭时恢复
  #:transparent)

;;; ════════════════ store 存取 / 查询 ════════════════

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
                   (input-state panel-id status-view input-view
                                #f #f #f #f "" 0 #f)))

;;; ════════════════ 前缀显示 ════════════════

;; 资源 confirm 的规范 choices 是 save/skip/save-all/skip-all，显示成 y/n/all/nall；
;; 插件请求的 confirm choices 就按 symbol 原样显示。
(define (choice-key c)
  (case c
    [(save) "y"]
    [(skip) "n"]
    [(save-all) "all"]
    [(skip-all) "nall"]
    [else (symbol->string c)]))

(define (take-width s budget)
  (let loop ([cs (string->list s)] [w 0] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [else
       (define cw (char-display-width (car cs)))
       (if (> (+ w cw) budget)
           (list->string (reverse acc))
           (loop (cdr cs) (+ w cw) (cons (car cs) acc)))])))

(define (string-reverse* s)
  (list->string (reverse (string->list s))))

(define (take-tail-width s budget)
  (string-reverse* (take-width (string-reverse* s) budget)))

;; 提示前缀必须能看见：太长就中间省略（保留开头和尾部）。
(define (fit-label label budget)
  (cond
    [(<= (string-display-width label) budget) label]
    [(<= budget 1) "…"]
    [else
     (define ell "…")
     (define inner (- budget (string-display-width ell)))
     (define head-budget (min inner (max 5 (quotient inner 3))))
     (define tail-budget (max 0 (- inner head-budget)))
     (string-append (take-width label head-budget)
                    ell
                    (take-tail-width label tail-budget))]))

;; label + 可选值提示；按 view 宽度裁剪 label，并给输入留几个字符。
(define (prefix-from label choices width)
  (define hint (if (and choices (pair? choices))
                   (string-append " ("
                                  (string-join (map choice-key choices) "/")
                                  ") ")
                   ""))
  (define reserve 6)
  (define budget (max 0 (- width (string-display-width hint) reserve)))
  (string-append (fit-label label budget) hint))

(define (prompt-prefix prompt width)
  (prefix-from (prompt-label prompt) (prompt-choices prompt) width))

(define (request-prefix req width)
  (prefix-from (input-request-label req)
               (and (eq? (input-request-kind req) 'confirm)
                    (input-request-choices req))
               width))

;;; ════════════════ 打开 / 关闭（view 切换 + 焦点） ════════════════

(define (switch-active-view state view-id)
  (define-values (layout* ok?)
    (layout-panel-set-active-view (app-state-layout state)
                                  (input-state-panel-id (input-state* state))
                                  view-id))
  (if ok? (struct-copy app-state state [layout layout*]) state))

;; 公共打开：source/request/prompt-id + 初始文本
(define (input-open state source request prompt-id text)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (or (input-state-prev-focus s)
                      (app-state-focus-panel-id state)))
     (define cursor (string-length text))
     (define s1 (struct-copy input-state s
                             [active? #t]
                             [source source]
                             [request request]
                             [prompt-id prompt-id]
                             [text text]
                             [cursor cursor]
                             [prev-focus prev]))
     (define state1 (set-input-state (switch-active-view state (input-state-input-view s)) s1))
     ;; 输入栏是在 status panel 里换 view：焦点 resource 变 #f
     (app-state-set-focus-panel state1 (input-state-panel-id s))]))

(define (open-resource-input state prompt)
  (input-open state 'resource #f (prompt-id prompt) ""))

(define (open-request-input state req)
  (input-open state 'plugin req #f (input-request-default req)))

(define (input-close state)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (input-state-prev-focus s))
     (define s1 (struct-copy input-state s
                             [active? #f]
                             [source #f]
                             [request #f]
                             [prompt-id #f]
                             [text ""]
                             [cursor 0]
                             [prev-focus #f]))
     (define state1 (set-input-state (switch-active-view state (input-state-status-view s)) s1))
     (cond
       [prev (app-state-set-focus-panel state1 prev)]
       [else state1])]))

;;; ════════════════ 插件请求 / 打断 ════════════════

;; 结束插件请求：先关闭输入栏，再把 input-result 交给 on-done。
;; → (values state' actions)
(define (finish-request state result)
  (define s (input-state* state))
  (define req (and s (input-state-request s)))
  (define closed (input-close state))
  (cond
    [(not req) (values closed '())]
    [else ((input-request-on-done req) closed result)]))

;; 插件发起输入（抢占式）：系统 prompt 优先；旧插件请求会被挤占。
(define (input-start state req)
  (define prompt (resource-prompt (app-state-resources state)))
  (define s (input-state* state))
  (cond
    [prompt
     (values (app-state-with-message state "input busy: system prompt") '())]
    [(and s (input-state-active? s) (eq? (input-state-source s) 'plugin))
     (define old (input-state-request s))
     (define-values (s1 actions)
       (finish-request state (input-result (input-request-id old) 'preempted #f)))
     (values (open-request-input s1 req) actions)]
    [else (values (open-request-input state req) '())]))

;; 当前输入被其他事件 / 新输入打断
(define (input-interrupt state status)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) (values state '())]
    [(eq? (input-state-source s) 'resource)
     (define prompt (resource-prompt (app-state-resources state)))
     (define store*
       (if prompt
           (resource-cancel (app-state-resources state) (prompt-id prompt))
           (app-state-resources state)))
     (values (input-close (struct-copy app-state state [resources store*])) '())]
    [else
     (define req (input-state-request s))
     (finish-request state (input-result (input-request-id req) status #f))]))

;;; ════════════════ 状态不变量：prompt / request <-> 输入栏 ════════════════
;;;
;;; 返回 (values state actions)：挤占插件请求时 on-done 可能产生 action。
(define (input-reconcile state)
  (define prompt (resource-prompt (app-state-resources state)))
  (define s (input-state* state))
  (cond
    [(not s) (values state '())]
    [else
     (define active? (input-state-active? s))
     (define source (input-state-source s))
     (cond
       ;; 系统 prompt 优先
       [prompt
        (cond
          [(and active? (eq? source 'plugin))
           ;; 插件输入被系统 prompt 挤占
           (define req (input-state-request s))
           (define-values (s1 actions)
             (finish-request state (input-result (input-request-id req) 'preempted #f)))
           (values (open-resource-input s1 prompt) actions)]
          [(and active? (eq? source 'resource)
                (equal? (input-state-prompt-id s) (prompt-id prompt)))
           (values state '())]
          [else
           (define base (if active? (input-close state) state))
           (values (open-resource-input base prompt) '())])]
       [else
        (cond
          [(and active? (eq? source 'resource)) (values (input-close state) '())]
          [(and active? (eq? source 'plugin)) (values state '())]
          [else (values state '())])])]))

;;; ════════════════ 同步到 core view ════════════════

(define (input-sync! state engine)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) state]
    [else
     (define prompt (and (eq? (input-state-source s) 'resource)
                         (resource-prompt (app-state-resources state))))
     (define req (and (eq? (input-state-source s) 'plugin)
                      (input-state-request s)))
     (define width (or (engine-view-width engine (input-state-input-view s)) 80))
     (define prefix (cond [prompt (prompt-prefix prompt width)]
                          [req (request-prefix req width)]
                          [else ""]))
     (define text (string-append prefix (input-state-text s)))
     (engine-set-view-lines! engine (input-state-input-view s)
                             (list text) (list 'input) 0
                             #:column (+ (string-length prefix)
                                         (input-state-cursor s))
                             ;; 前缀只读 + 单独 face；编辑只作用于后面
                             #:readonly-prefix (string-length prefix)
                             #:prefix-face 'input-prompt)
     state]))

;;; ════════════════ 单行编辑 ════════════════

(define (text-insert text i s)
  (values (string-append (substring text 0 i) s (substring text i))
          (+ i (string-length s))))

(define (text-delete-before text i)
  (cond
    [(zero? i) (values text i)]
    [else (values (string-append (substring text 0 (sub1 i)) (substring text i))
                  (sub1 i))]))

(define (text-delete-at text i)
  (cond
    [(>= i (string-length text)) (values text i)]
    [else (values (string-append (substring text 0 i) (substring text (add1 i)))
                  i)]))

;; 单行输入：保留可打印字符和空格，丢掉控制字符 / 换行
(define (sanitize-single-line s)
  (list->string
   (for/list ([c (in-string s)]
              #:when (or (char-graphic? c) (char=? c #\space)))
     c)))

;; 输入栏和 edit 共用 key-text：'key / 'utf8 的 token -> 文本，其它 -> #f
(define (input-typed-text tok)
  (and (key? tok) (key-text tok)))

(define (tok=? a b)
  (and (key? a) (key=? a b)))

;;; ════════════════ Enter：提交 ════════════════

(define (prompt-invalid-message prompt)
  (case (prompt-kind prompt)
    [(confirm)
     (format "answer: ~a" (string-join (map choice-key (prompt-choices prompt))
                                       " / "))]
    [(save-path) "path required"]
    [else "invalid input"]))

(define (request-invalid-message req)
  (format "answer: ~a"
          (string-join (map choice-key (input-request-choices req)) " / ")))

(define (input-submit state)
  (define prompt (resource-prompt (app-state-resources state)))
  (define s (input-state* state))
  (cond
    [prompt
     (define-values (store* actions ok?)
       (resource-submit-text (app-state-resources state)
                             (prompt-id prompt)
                             (input-state-text s)))
     (cond
       [(not ok?)
        (values (app-state-with-message state (prompt-invalid-message prompt)) '())]
       [else
        (values (input-close (struct-copy app-state state [resources store*])) actions)])]
    [(and s (eq? (input-state-source s) 'plugin))
     (define req (input-state-request s))
     (define raw (input-state-text s))
     (case (input-request-kind req)
       [(confirm)
        (define v (string->symbol (string-downcase (string-trim raw))))
        (cond
          [(memq v (input-request-choices req))
           (finish-request state (input-result (input-request-id req) 'submitted v))]
          [else
           (values (app-state-with-message state (request-invalid-message req)) '())])]
       [else
        (finish-request state (input-result (input-request-id req) 'submitted raw))])]
    [else (values (input-close state) '())]))

;;; ════════════════ 按键 / 粘贴 ════════════════

(define (input-cancel-current state)
  (define s (input-state* state))
  (cond
    [(eq? (input-state-source s) 'resource)
     (define prompt (resource-prompt (app-state-resources state)))
     (define store*
       (if prompt
           (resource-cancel (app-state-resources state) (prompt-id prompt))
           (app-state-resources state)))
     (values (input-close (struct-copy app-state state [resources store*])) '())]
    [else
     (define req (input-state-request s))
     (finish-request state (input-result (input-request-id req) 'cancelled #f))]))

(define (input-handle-key state ev)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) #f]
    [else
     (define tok (key-event-token ev))
     (define text (input-state-text s))
     (define cursor (input-state-cursor s))
     (cond
       [(or (tok=? tok (key 'g 'ctrl)) (tok=? tok (key 'escape)))
        (input-cancel-current state)]
       [(tok=? tok (key 'enter))
        (input-submit state)]
       [(tok=? tok (key 'backspace))
        (define-values (text* cursor*) (text-delete-before text cursor))
        (values (set-input-state state (struct-copy input-state s
                                                    [text text*] [cursor cursor*]))
                '())]
       [(tok=? tok (key 'delete))
        (define-values (text* cursor*) (text-delete-at text cursor))
        (values (set-input-state state (struct-copy input-state s
                                                    [text text*] [cursor cursor*]))
                '())]
       [(or (tok=? tok (key 'left)) (tok=? tok (key 'b 'ctrl)))
        (values (set-input-state state (struct-copy input-state s
                                                    [cursor (max 0 (sub1 cursor))]))
                '())]
       [(or (tok=? tok (key 'right)) (tok=? tok (key 'f 'ctrl)))
        (values (set-input-state state (struct-copy input-state s
                                                    [cursor (min (string-length text) (add1 cursor))]))
                '())]
       [(or (tok=? tok (key 'home)) (tok=? tok (key 'a 'ctrl)))
        (values (set-input-state state (struct-copy input-state s [cursor 0])) '())]
       [(or (tok=? tok (key 'end)) (tok=? tok (key 'e 'ctrl)))
        (values (set-input-state state (struct-copy input-state s
                                                    [cursor (string-length text)]))
                '())]
       [else
        (define typed (input-typed-text tok))
        (cond
          [(not typed) (values state '())]
          [else
           (define-values (text* cursor*) (text-insert text cursor typed))
           (values (set-input-state state (struct-copy input-state s
                                                       [text text*] [cursor cursor*]))
                   '())])])]))

;; 粘贴：只取单行可打印内容，插到光标处
(define (input-handle-paste state ev)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) #f]
    [else
     (define pasted (sanitize-single-line
                     (bytes->string/utf-8 (paste-event-bytes ev) (integer->char 65533))))
     (define-values (text* cursor*)
       (text-insert (input-state-text s) (input-state-cursor s) pasted))
     (values (set-input-state state (struct-copy input-state s
                                                 [text text*] [cursor cursor*]))
             '())]))
