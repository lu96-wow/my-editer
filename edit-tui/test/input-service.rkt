#lang racket

;;; 输入栏服务：插件请求 / 打断 / 挤占 / 结果回调。
(require rackunit
         (only-in "../../core/editor.rkt" view-buffer buffer-readonly-at? buffer-string)
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt"
         "../main.rkt")

;;; ════════════════ 最小 app：editor + status/input ════════════════

(define (make-app)
  (define engine (make-engine))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "main"
                   #:text "hello"
                   #:key-table (buffer-key-table #f "hello")))
  (define rid (resource-id (car (resource-list store))))
  (void (run-actions (make-app-state) engine actions))
  (void (engine-create-buffer! engine 20 "*status*" ""))
  (void (engine-create-view! engine 20 20))
  (void (engine-create-buffer! engine 21 "*input*" ""))
  (void (engine-create-view! engine 21 21))
  (define editor-panel
    (make-panel 'editor 'editor #:views '(1) #:active 1
                #:borders '(up down left right)))
  (define status-panel
    (make-panel 'status 'status #:views '(20 21) #:active 20
                #:fixed-h 1 #:borders '(up)))
  (define-values (layout ok?)
    (layout-panel-attach
     (make-layout #:root (make-leaf 'editor)
                  #:panels (hash 'editor editor-panel)
                  #:focus 'editor)
     'editor 'down status-panel))
  (check-true ok?)
  (define state (make-app-state #:layout layout
                                #:resources store
                                #:focus-resource rid
                                #:keymap default-keymap
                                #:area (rect 0 0 60 8)))
  (define s1 (status-install-state state 20))
  (define s2 (input-install-state s1 'status 20 21))
  (define s3 (run-actions s2 engine actions))
  (let-values ([(cache bytes) (render-frame s3 engine #f)])
    (void cache) (void bytes))
  (values s3 engine rid))

(define (sync! state engine)
  (define s (sync-ui! state engine))
  (let-values ([(c b) (render-frame s engine #f)]) (void c) (void b))
  s)

(define (press/actions state engine tok)
  (define-values (s a) (step state (key-event tok)))
  (values (sync! (run-actions s engine a) engine) a))

(define (press state engine tok)
  (let-values ([(s a) (press/actions state engine tok)]) (void a) s))

(define (type state engine str)
  (for/fold ([s state]) ([c (in-string str)])
    (press s engine (key c))))

(define (view-line engine) (engine-view-text engine 21))

;; 结果记录在 store['last-result]，方便断言
(define (result-handler id)
  (λ (state result)
    (values (struct-copy app-state state
                         [store (hash-set (app-state-store state)
                                          'last-result (list id result))])
            '())))

(define (last-result state)
  (hash-ref (app-state-store state) 'last-result #f))

(define (start state engine req)
  (let-values ([(s a) (input-start state req)])
    (run-actions s engine a)))

(define (req id label kind choices default)
  (input-request id label kind choices default (result-handler id)))

;;; ════════════════ text 请求：编辑 + 提交 ════════════════
(define-values (s0 e0 r0) (make-app))
(define s1 (start s0 e0 (req 'name "Name: " 'text '() "def")))
(define s2 (sync! s1 e0))
(check-true (input-active? s2))
(check-equal? (view-line e0) "Name: def")
;; 前缀 readonly，编辑只作用于后面
(define in-buffer (view-buffer (engine-view-object e0 21)))
(check-true (buffer-readonly-at? in-buffer 0 0))
(check-false (buffer-readonly-at? in-buffer 0 6))

;; 光标按 End 后输入 X，再 Backspace
(define s3 (press s2 e0 (key 'end)))
(define s4 (type s3 e0 "X"))
(check-equal? (view-line e0) "Name: defX")
(define s5 (press s4 e0 (key 'backspace)))
(check-equal? (view-line e0) "Name: def")
(define s6 (type s5 e0 "42"))
(define-values (s7 _a7) (press/actions s6 e0 (key 'enter)))
(check-false (input-active? s7))
(check-equal? (last-result s7) (list 'name (input-result 'name 'submitted "def42")))
(define s8 (sync! s7 e0))
;; 输入栏已关闭：status panel 回到 status view
(check-equal? (panel-active (layout-panel (app-state-layout s8) 'status)) 20)

;;; ════════════════ confirm 请求：校验 + Esc 取消 ════════════════
(define-values (c0 ce0 cr0) (make-app))
(define c1 (start c0 ce0 (req 'ok "Continue? " 'confirm '(yes no) "")))
(define c2 (sync! c1 ce0))
(check-equal? (view-line ce0) "Continue?  (yes/no) ")
;; 非法答案：不提交、提示可选值
(define c3 (type c2 ce0 "maybe"))
(define-values (c4 _a4) (press/actions c3 ce0 (key 'enter)))
(check-true (input-active? c4))
(check-true (string-contains? (app-state-flash c4) "answer:"))
;; 合法答案（大小写不敏感）
(define c5 (press c4 ce0 (key 'escape)))
(define c6 (start c5 ce0 (req 'ok2 "Continue? " 'confirm '(yes no) "")))
(define c7 (sync! c6 ce0))
(define c8 (type c7 ce0 "YES"))
(define c9 (press c8 ce0 (key 'enter)))
(check-equal? (last-result c9) (list 'ok2 (input-result 'ok2 'submitted 'yes)))

;;; ════════════════ Esc 取消：on-done 'cancelled ════════════════
(define-values (x0 xe0 _xr) (make-app))
(define x1 (start x0 xe0 (req 'x "X: " 'text '() "")))
(define x2 (sync! x1 xe0))
(define x3 (press x2 xe0 (key 'escape)))
(check-false (input-active? x3))
(check-equal? (last-result x3) (list 'x (input-result 'x 'cancelled #f)))

;;; ════════════════ 新请求挤占旧请求 ════════════════
(define-values (p0 pe0 _pr) (make-app))
(define p1 (start p0 pe0 (req 'old "Old: " 'text '() "old")))
(define p2 (sync! p1 pe0))
(define p3 (start p2 pe0 (req 'new "New: " 'text '() "new")))
(check-equal? (last-result p3) (list 'old (input-result 'old 'preempted #f)))
(define p4 (sync! p3 pe0))
(check-equal? (view-line pe0) "New: new")

;;; ════════════════ 其他事件打断输入 ════════════════
;; resize：先取消输入，再处理 resize
(define-values (e1 _ea) (step p4 (resize-event 10 40)))
(check-false (input-active? e1))
(check-equal? (last-result e1) (list 'new (input-result 'new 'cancelled #f)))
(check-equal? (app-state-area e1) (rect 0 0 40 10))

;; mouse：取消后照常聚焦 / 落点
(define-values (m0 me0 _mr) (make-app))
(define m1 (start m0 me0 (req 'm "M: " 'text '() "")))
(define m2 (sync! m1 me0))
(define-values (m3 _ma) (step m2 (mouse-event 'press 2 2)))
(check-false (input-active? m3))
(check-equal? (last-result m3) (list 'm (input-result 'm 'cancelled #f)))
(check-equal? (layout-focus (app-state-layout m3)) 'editor)

;;; ════════════════ 系统 prompt 挤占插件请求 ════════════════
(define-values (q0 qe0 qr0) (make-app))
(define q1 (start q0 qe0 (req 'plug "Plug: " 'text '() "")))
(define q2 (sync! q1 qe0))
;; 造一个 resource prompt（save-path）
(define-values (store* _as) (resource-save (app-state-resources q2) qr0))
(define-values (q3 actions3) (input-reconcile (struct-copy app-state q2 [resources store*])))
(check-equal? (last-result q3) (list 'plug (input-result 'plug 'preempted #f)))
(check-true (input-active? q3))
(check-equal? (prompt-kind (resource-prompt (app-state-resources q3))) 'save-path)
(check-equal? (map resource-action-kind actions3) '())

;;; ════════════════ 系统 prompt 也会被其他事件取消 ════════════════
(define q4 (sync! (run-actions q3 qe0 actions3) qe0))
(check-true (input-active? q4))
(define-values (q5 _qa5) (step q4 (mouse-event 'press 2 2)))
(check-false (input-active? q5))
(check-false (resource-prompt (app-state-resources q5)))
(check-false (app-state-quit? q5))

;;; ════════════════ 长提示：不裁剪，光标可以走进前缀 ════════════════
(define-values (l0 le0 _lr) (make-app))
(define long-label (string-append "Very long prompt: " (make-string 70 #\a) ": "))
(define l1 (start l0 le0 (req 'long long-label 'text '() "tail")))
(define l2 (sync! l1 le0))
(define full (string-append long-label "tail"))
(define line (view-line le0))
(check-equal? line full)                       ; 提示完整写在 buffer 里
(check-false (string-contains? line "…"))
;; 前缀 readonly
(define l-buffer (view-buffer (engine-view-object le0 21)))
(check-true (buffer-readonly-at? l-buffer 0 0))
(check-true (buffer-readonly-at? l-buffer 0 (sub1 (string-length long-label))))
(check-false (buffer-readonly-at? l-buffer 0 (string-length long-label)))
;; 打开时在行尾；Home 到行首（前缀里），Right 逐步进入前缀
(check-equal? (engine-view-point-column le0 21) (string-length full))
(define l3 (press l2 le0 (key 'home)))
(check-equal? (engine-view-point-column le0 21) 0)
(define l4 (press l3 le0 (key 'right)))
(check-equal? (engine-view-point-column le0 21) 1)
;; 光标在前缀里插入：落到文本起点，前缀不变
(define l5 (type l4 le0 "Z"))
(check-equal? (view-line le0) (string-append long-label "Ztail"))
;; 前缀里 Backspace / Delete 不碰前缀
(define l6 (press l5 le0 (key 'home)))
(define l7 (press l6 le0 (key 'backspace)))
(check-equal? (view-line le0) (string-append long-label "Ztail"))
(define l8 (press l7 le0 (key 'delete)))
(check-equal? (view-line le0) (string-append long-label "Ztail"))

(displayln "edit-tui-rebuild/test/input-service.rkt: ok")
