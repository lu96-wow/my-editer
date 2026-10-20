#lang racket

;;; edit-tui-rebuild/chrome/input.rkt —— 输入栏（服务插件）
;;;
;;; 输入栏是普通 core view：一行 = prompt 前缀 + 输入文本 + 光标。
;;; 文本 / 光标归 State（input-state），每帧投影到 view。
;;;
;;; 前缀用 core 的 readonly 属性保护（不裁剪、不省略）：提示完整写在 buffer 里，
;;; 光标可以 ←/→/Home/End 走进前缀区域查看（编辑操作碰不到前缀）。
;;;
;;; 两种输入来源：
;;;   1. resource prompt（骨架资源管理产生）：save-path / confirm
;;;   2. 插件请求：(input-start state (input-request ...))，
;;;      on-done 回调拿到 (input-result id status value)
;;;
;;; 按键走命令表：输入激活时 app/step 只用 keymap 的 input-stack（独占），
;;; **不叠 overlays** —— stack 查找 unbound 会落到下一张表，叠 overlay 会让
;;; C-q 之类的全局键穿透输入栏。可打印字符不在表里，由 input-self-insert 兜底。
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
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/event.rkt")

(provide input-install-state
         input-active?
         input-reconcile
         input-sync!
         input-cancel-current
         input-submit
         input-home
         input-end
         input-backspace
         input-delete
         input-left
         input-right
         input-self-insert
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
   cursor       ; 整行绝对光标（0 .. 前缀长 + 文本长）
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

(define (label-with-choices label choices)
  (define hint (if (and choices (pair? choices))
                   (string-append " ("
                                  (string-join (map choice-key choices) "/")
                                  ") ")
                   ""))
  (string-append label hint))

(define (resource-prefix prompt)
  (label-with-choices (prompt-label prompt) (prompt-choices prompt)))

(define (request-prefix req)
  (label-with-choices (input-request-label req)
                      (and (eq? (input-request-kind req) 'confirm)
                           (input-request-choices req))))

(define (current-prefix state)
  (define s (input-state* state))
  (cond
    [(not s) ""]
    [(eq? (input-state-source s) 'resource)
     (define prompt (resource-prompt (app-state-resources state)))
     (if prompt (resource-prefix prompt) "")]
    [(eq? (input-state-source s) 'plugin)
     (define req (input-state-request s))
     (if req (request-prefix req) "")]
    [else ""]))

(define (switch-active-view state view-id)
  (define-values (layout* ok?)
    (layout-panel-set-active-view (app-state-layout state)
                                  (input-state-panel-id (input-state* state))
                                  view-id))
  (if ok? (struct-copy app-state state [layout layout*]) state))

; 公共打开：source/request/prompt-id + 初始文本（cursor 是整行绝对位置）
(define (input-open state source request prompt-id prefix-len text)
  (define s (input-state* state))
  (cond
    [(not s) state]
    [else
     (define prev (or (input-state-prev-focus s)
                      (app-state-focus-panel-id state)))
     (define cursor (+ prefix-len (string-length text)))
     (define s1 (struct-copy input-state s
                             [active? #t]
                             [source source]
                             [request request]
                             [prompt-id prompt-id]
                             [text text]
                             [cursor cursor]
                             [prev-focus prev]))
     (define state1 (set-input-state (switch-active-view state (input-state-input-view s)) s1))
     ;; 输入是模态：清掉半截键序列，否则第一键会按 (pending ++ tok) 去查表。
     (define state2 (struct-copy app-state state1 [pending '()]))
     ;; 输入栏是在 status panel 里换 view：焦点 resource 变 #f
     (app-state-set-focus-panel state2 (input-state-panel-id s))]))

(define (open-resource-input state prompt)
  (input-open state 'resource #f (prompt-id prompt)
              (string-length (resource-prefix prompt)) ""))

(define (open-request-input state req)
  (input-open state 'plugin req #f
              (string-length (request-prefix req))
              (input-request-default req)))

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
     (define prefix (current-prefix state))
     (define text (string-append prefix (input-state-text s)))
     (define cursor (max 0 (min (input-state-cursor s) (string-length text))))
     (engine-set-view-lines! engine (input-state-input-view s)
                             (list text) (list 'input) 0
                             #:column cursor
                             ;; 前缀只读 + 单独 face；光标可以走进去看，编辑碰不到
                             #:readonly-prefix (string-length prefix)
                             #:prefix-face 'input-prompt)
     state]))

;;; ════════════════ 单行编辑 ════════════════
;;;
;;; cursor 是整行的绝对位置（0 .. 前缀长 + 文本长）。
;;; 前缀是 readonly：光标可以进去看，但插入 / 删除只作用于前缀之后的文本。

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

(define (input-typed-text tok)
  (and (key? tok) (key-text tok)))

(define (prefix-length state)
  (string-length (current-prefix state)))

(define (line-end-cursor state)
  (+ (prefix-length state)
     (string-length (input-state-text (input-state* state)))))

(define (set-cursor state cursor)
  (set-input-state state
                   (struct-copy input-state (input-state* state)
                                [cursor (max 0 cursor)])))

;; 光标在前缀里时，插入落到可编辑文本的起点（不会改前缀）。
(define (input-insert state s)
  (define st (input-state* state))
  (define pl (prefix-length state))
  (define idx (max 0 (- (input-state-cursor st) pl)))
  (define-values (text* cursor*) (text-insert (input-state-text st) idx s))
  (values (set-input-state state
                           (struct-copy input-state st
                                        [text text*]
                                        [cursor (+ pl cursor*)]))
          '()))

(define (input-backspace state)
  (define st (input-state* state))
  (define pl (prefix-length state))
  (define idx (- (input-state-cursor st) pl))
  (cond
    [(<= idx 0) (values state '())]      ; 前缀 / 文本头：不许删
    [else
     (define-values (text* cursor*) (text-delete-before (input-state-text st) idx))
     (values (set-input-state state
                              (struct-copy input-state st
                                           [text text*]
                                           [cursor (+ pl cursor*)]))
             '())]))

(define (input-delete state)
  (define st (input-state* state))
  (define pl (prefix-length state))
  (define idx (- (input-state-cursor st) pl))
  (cond
    [(< idx 0) (values state '())]       ; 光标在前缀里：Delete 不碰文本
    [else
     (define-values (text* cursor*) (text-delete-at (input-state-text st) idx))
     (values (set-input-state state
                              (struct-copy input-state st
                                           [text text*]
                                           [cursor (+ pl cursor*)]))
             '())]))

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

;;; ════════════════ 命令（输入态独占表） ════════════════
;;;
;;; 这里只放“按键 -> 已有 input-* 函数”的包装；真正编辑逻辑仍在上面。
;;; 可打印字符不建表项：任意 Unicode 都走 input-self-insert 兜底。

(define (input-home state)
  (values (set-cursor state 0) '()))

(define (input-end state)
  (values (set-cursor state (line-end-cursor state)) '()))

(define (input-left state)
  (define cursor (input-state-cursor (input-state* state)))
  (values (set-cursor state (max 0 (sub1 cursor))) '()))

(define (input-right state)
  (define cursor (input-state-cursor (input-state* state)))
  (values (set-cursor state (min (line-end-cursor state) (add1 cursor))) '()))

;; 表未命中：可打印字符插入；控制键吞掉（不冒泡成 "unbound"）。
(define (input-self-insert state tok)
  (define typed (input-typed-text tok))
  (cond
    [typed (input-insert state typed)]
    [else (values state '())]))

;; 粘贴：只取单行可打印内容，插到光标处（光标在前缀里则落到文本起点）
(define (input-handle-paste state ev)
  (define s (input-state* state))
  (cond
    [(not (and s (input-state-active? s))) #f]
    [else
     (define pasted (sanitize-single-line
                     (bytes->string/utf-8 (paste-event-bytes ev) (integer->char 65533))))
     (input-insert state pasted)]))
