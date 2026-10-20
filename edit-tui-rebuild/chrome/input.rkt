#lang racket

;;; edit-tui-rebuild/chrome/input.rkt —— 输入栏（单行编辑 + prompt）
;;;
;;; 输入栏是普通 core view：一行 = prompt 前缀 + 输入文本 + 光标。
;;; 文本 / 光标归 State（input-state），每帧投影到 view。
;;;
;;; 交互：
;;;   可打印键 / paste       在光标处插入
;;;   Backspace / Delete     删光标前 / 后
;;;   ← → Home End C-a C-e   移动光标
;;;   Enter                  提交（confirm 校验选项；save-path 拒绝空路径）
;;;   Esc / C-g              取消（resource-cancel）
;;;
;; prompt 来自 resource manager；文本 -> 值的转换 / 校验在
;;; resource-submit-text（按 prompt kind 分派），输入栏不判断 kind。
;;;
;;; 输入模式激活时 step 直接接管按键 / 粘贴，不查普通命令表。

(require racket/string
         "../skeleton/api.rkt"
         "../app/state.rkt"
         "../app/event.rkt")

(provide input-install-state
         input-active?
         input-reconcile
         input-sync!
         input-handle-key
         input-handle-paste)

(struct input-state
  (panel-id     ; 输入栏所在的 panel（status panel）
   status-view  ; 平时显示的 view
   input-view   ; 输入时显示的 view
   active?
   text         ; 已输入文本（不含 prompt 前缀）
   cursor       ; 文本内光标（0..string-length）
   prev-focus)  ; 打开输入栏前的焦点 panel，关闭时恢复
  #:transparent)

;;; ════════════════ store 存取 ════════════════

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
                   (input-state panel-id status-view input-view #f "" 0 #f)))

;;; ════════════════ 打开 / 关闭 ════════════════

;; 输入栏显示的前缀：label（confirm 再补上可选项提示）。
;;
;; confirm 的 choices 是规范 symbol（save/skip/save-all/skip-all），
;; 显示成 y/n/all/nall；resource-submit-text 两种写法都接受。
(define (choice-key c)
  (case c
    [(save) "y"]
    [(skip) "n"]
    [(save-all) "all"]
    [(skip-all) "nall"]
    [else (symbol->string c)]))

;; 按显示宽度取前 n 列 / 后 n 列（prompt 太长时中间省略）
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

;; 提示前缀必须能看见：太长就中间省略（保留 "Save " 和路径尾部）。
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

;; label + 可选项提示；按 view 宽度裁剪 label，并给输入留几个字符。
(define (prompt-prefix prompt width)
  (define label (prompt-label prompt))
  (define choices (prompt-choices prompt))
  (define hint (if (and choices (pair? choices))
                   (string-append " ("
                                  (string-join (map choice-key choices) "/")
                                  ") ")
                   ""))
  (define reserve 6)
  (define budget (max 0 (- width (string-display-width hint) reserve)))
  (string-append (fit-label label budget) hint))

(define (switch-active-view state view-id)
  (define-values (layout* ok?)
    (layout-panel-set-active-view (app-state-layout state)
                                  (input-state-panel-id (input-state* state))
                                  view-id))
  (if ok? (struct-copy app-state state [layout layout*]) state))

(define (input-open state)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (or (input-state-prev-focus s)
                      (app-state-focus-panel-id state)))
     (define s1 (struct-copy input-state s
                             [active? #t]
                             [text ""]
                             [cursor 0]
                             [prev-focus prev]))
     (define state1 (set-input-state (switch-active-view state (input-state-input-view s)) s1))
     ;; 输入栏是在 status panel 里换 view：焦点 resource 变 #f
     (app-state-set-focus-panel state1 (input-state-panel-id s))]))

(define (input-close state)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (input-state-prev-focus s))
     (define s1 (struct-copy input-state s
                             [active? #f]
                             [text ""]
                             [cursor 0]
                             [prev-focus #f]))
     (define state1 (set-input-state (switch-active-view state (input-state-status-view s)) s1))
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

;; 状态不变量：有 prompt <=> 输入栏打开。
;; 这是纯状态迁移（不碰 engine），由 step 在入口 / 出口调用，
;; 所以「不调 sync / 不渲染」的宿主也不会丢 Enter。
(define (input-reconcile state)
  (define prompt (resource-prompt (app-state-resources state)))
  (define s (input-state* state))
  (cond
    [(not s) state]
    [(and prompt (not (input-state-active? s))) (input-open state)]
    [(and (not prompt) (input-state-active? s)) (input-close state)]
    [else state]))

;;; ════════════════ 同步到 core view ════════════════

(define (input-sync! state engine)
  (define state1 (input-reconcile state))
  (define prompt (resource-prompt (app-state-resources state1)))
  (define s1 (input-state* state1))
  (cond
    [(and s1 (input-state-active? s1))
     (define width (or (engine-view-width engine (input-state-input-view s1)) 80))
     (define prefix (if prompt (prompt-prefix prompt width) ""))
     (define text (string-append prefix (input-state-text s1)))
     (engine-set-view-lines! engine (input-state-input-view s1)
                             (list text) (list 'input) 0
                             #:column (+ (string-length prefix)
                                         (input-state-cursor s1))
                             ;; prompt 前缀只读 + 单独 face；编辑只作用于后面
                             #:readonly-prefix (string-length prefix)
                             #:prefix-face 'input-prompt)]
    [else (void)])
  state1)

;;; ════════════════ 单行编辑 ════════════════

(define (clamp-cursor text i)
  (max 0 (min i (string-length text))))

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

;;; ════════════════ Enter：提交到 resource API ════════════════

(define (prompt-invalid-message prompt)
  (case (prompt-kind prompt)
    [(confirm)
     (format "answer: ~a" (string-join (map choice-key (prompt-choices prompt))
                                       " / "))]
    [(save-path) "path required"]
    [else "invalid input"]))

(define (input-submit state)
  (define prompt (resource-prompt (app-state-resources state)))
  (cond
    [(not prompt) (values (input-close state) '())]
    [else
     (define s (input-state* state))
     (define-values (store* actions ok?)
       (resource-submit-text (app-state-resources state)
                             (prompt-id prompt)
                             (input-state-text s)))
     (cond
       [(not ok?)
        (values (app-state-with-message state (prompt-invalid-message prompt)) '())]
       [else
        (values (input-close (struct-copy app-state state [resources store*])) actions)])]))

;;; ════════════════ 按键 / 粘贴 ════════════════

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
        (input-cancel state)]
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
