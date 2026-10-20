#lang racket

;;; 退出保存流程：dirty -> C-q -> confirm -> save/save-path -> 写文件 -> quit
;;; （以及 skip / cancel / 无效回答）。

(require rackunit
         racket/file
         (only-in "../../core/editor.rkt" view-buffer buffer-readonly-at?)
         "../main.rkt")

;;; ════════════════ 最小 app：editor + status/input + 全局表 ════════════════

(define (quit-command state)
  (define-values (store* actions)
    (resource-request-quit (app-state-resources state)))
  (values (struct-copy app-state state [resources store*]) actions))

(define global-command-table
  (keys [(key 'q 'ctrl) quit-command]))

(define (make-app text #:path [path #f])
  (define engine (make-engine))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "main"
                   #:path path
                   #:text text
                   #:tables (list edit-command-table)))
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
                                #:overlays (list global-command-table)
                                #:editor-tables (list edit-command-table)
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

(define (prompt-of state) (resource-prompt (app-state-resources state)))

;;; ════════════════ skip：不写文件直接退出 ════════════════

(define-values (a0 ae0 ar0) (make-app "hello"))
(define a1 (press a0 ae0 (key 'x)))            ; 编辑 -> dirty
(check-true (resource-dirty? (app-state-resources a1) ar0))
(define a2 (press a1 ae0 (key 'q 'ctrl)))      ; C-q -> confirm
(check-true (input-active? a2))
(check-equal? (prompt-kind (prompt-of a2)) 'confirm)
(check-true (string-contains? (prompt-label (prompt-of a2)) "main"))
(define a3 (type a2 ae0 "n"))
(define a4 (press a3 ae0 (key 'enter)))
(check-true (app-state-quit? a4))
(check-false (input-active? a4))
(check-false (prompt-of a4))

;;; ════════════════ cancel：清 prompt，不退出 ════════════════

(define-values (c0 ce0 cr0) (make-app "hello"))
(define c1 (press c0 ce0 (key 'x)))
(define c2 (press c1 ce0 (key 'q 'ctrl)))
(define c3 (press c2 ce0 (key 'escape)))
(check-false (app-state-quit? c3))
(check-false (prompt-of c3))
(check-false (input-active? c3))
(check-true (resource-dirty? (app-state-resources c3) cr0))

;;; ════════════════ 无效回答：输入栏保持打开，提示可选值 ════════════════

(define d2 (press c3 ce0 (key 'q 'ctrl)))
(define d3 (type d2 ce0 "bogus"))
(define-values (d4 dActions) (press/actions d3 ce0 (key 'enter)))
(check-equal? dActions '())
(check-true (input-active? d4))
(check-false (app-state-quit? d4))
(check-true (string-contains? (app-state-message d4) "answer:"))
(check-not-false (prompt-of d4))

;;; ════════════════ save：confirm -> save-path -> write -> quit ════════════════

;; 无效回答后 Esc 取消，再走完整保存流程
(define e1 (press d4 ce0 (key 'escape)))
(define e2 (press e1 ce0 (key 'q 'ctrl)))
(define e3 (type e2 ce0 "y"))
(define e4 (press e3 ce0 (key 'enter)))
(check-equal? (prompt-kind (prompt-of e4)) 'save-path)

(define path "tmp-quit-save-test.txt")
(when (file-exists? path) (delete-file path))
(define e5 (type e4 ce0 path))
(define-values (e6 eActions) (press/actions e5 ce0 (key 'enter)))
(check-equal? (map resource-action-kind eActions) '(write-file))
(check-true (file-exists? path))
(check-true (app-state-quit? e6))
(check-false (resource-dirty? (app-state-resources e6) cr0))
(check-equal? (resource-path (app-state-resources e6) cr0) path)
(delete-file path)

;;; ---------- step-only：不调 sync / render 也能按 Enter 提交 ----------
;;; （prompt -> 输入栏这个不变量由 step 维护，而不是等 sync / 渲染）
(define (step-only state engine ev)
  (define-values (s a) (step state ev))
  (run-actions s engine a))

(define-values (f0 fe0 fr0) (make-app "hello"))
(define f1 (step-only f0 fe0 (key-event (key 'x))))         ; 编辑 -> dirty
(define f2 (step-only f1 fe0 (key-event (key 'q 'ctrl))))   ; C-q -> confirm（没 sync）
(check-true (input-active? f2))
(check-equal? (prompt-kind (prompt-of f2)) 'confirm)

(define f3 (for/fold ([s f2])
                      ([c (in-string "skip")])
              (step-only s fe0 (key-event (key c)))))
;; Enter 走终端 raw 事件（type . bytes），再经适配成 app 事件
(define f4 (step-only f3 fe0 (tui-event->app 'key #"\r" #f)))
(check-true (app-state-quit? f4))
(check-false (input-active? f4))

;;; ---------- 有 path：提示带路径 + 前缀 readonly + y 直接写文件 ----------
(define target (path->string (make-temporary-file "edit-tui-save-~a.txt")))
(define-values (p0 pe0 pr0) (make-app "hello" #:path target))
(define p1 (press p0 pe0 (key 'x)))            ; dirty
(define p2 (press p1 pe0 (key 'q 'ctrl)))      ; confirm
(check-true (input-active? p2))
;; 提示完整写在 buffer 里（不裁剪）；窗口窄时靠光标滚动查看
(define label (prompt-label (prompt-of p2)))
(check-true (string-contains? label target))
(define line (engine-view-text pe0 21))
(check-true (string-prefix? line (string-append "Save " target "? (y/n/all/nall) ")))
(check-false (string-contains? line "…"))
;; 行首渲染能看到 "Save "，行尾能看到可选值
(define p2h (press p2 pe0 (key 'home)))
(let-values ([(cache bytes) (render-frame p2h pe0 #f)])
  (void cache)
  ;; 行首有光标 overlay，抓可见的提示内容即可
  (check-true (string-contains? (bytes->string/utf-8 bytes) "ave ")))
(define p2e (press p2h pe0 (key 'end)))
(let-values ([(cache bytes) (render-frame p2e pe0 #f)])
  (void cache)
  (check-true (string-contains? (bytes->string/utf-8 bytes) "y/n/all/nall")))
;; prompt 前缀在 buffer 里是 readonly（光标可进去看，编辑碰不到）
(define in-view (engine-view-object pe0 21))
(define in-buffer (view-buffer in-view))
(define prefix-len (string-length line))
(check-true (buffer-readonly-at? in-buffer 0 0))
(check-true (buffer-readonly-at? in-buffer 0 (sub1 prefix-len)))
(check-false (buffer-readonly-at? in-buffer 0 prefix-len))
;; y -> 直接写 target 并退出
(define p3 (type p2e pe0 "y"))
(define-values (p4 pActions) (press/actions p3 pe0 (key 'enter)))
(check-equal? (map resource-action-kind pActions) '(write-file))
(check-true (app-state-quit? p4))
(check-true (file-exists? target))
(delete-file target)

(displayln "edit-tui-rebuild/test/quit-save.rkt: ok")
