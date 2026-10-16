#lang racket

;;; 23 —— app 事件循环骨架 demo（world + step + intent + loop）
;;;
;;;   racket temp/23-app-loop.rkt          # headless：喂合成事件，看 world 与 intent
;;;   racket temp/23-app-loop.rkt tui      # 交互（真终端）
;;;
;;; 这个 demo 只为演示 app/ 骨架的用法：
;;;   · 命令是纯的：(λ (ctx) (listof intent))，不直接改 core；
;;;   · world 是纯数据：布局 / 焦点 / pending / drag 全在里面；
;;;   · 交互与 headless 走同一条 world-step，无需终端即可自检。
;;;
;;; 键位：
;;;   ←/→/↑/↓ Home End   光标
;;;   Enter / Backspace   编辑
;;;   可打印字符           插入
;;;   C-b                 开关 tree 面板（纯 world 变换）
;;;   C-t                 起一个异步任务（spawn → inbox → 下一事件时处理）
;;;   鼠标                点击落光标 / 拖动选区 / 点缝拖大小 / 滚轮
;;;   C-x C-c             退出

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 视图 / 布局 ════════════════

(define W 80)
(define H 24)

(define eb (make-buffer "(define (f x)\n  ;; doc\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define eview (buffer-add-view! eb))
(define tb (make-buffer "src/\n  main.rkt\n  util.rkt\n  panel.rkt\nREADME.md" "*tree*"))
(define tview (buffer-add-view! tb))

(define (base-layout)
  (lay 'lr
       (pane 'tree   #:view tview #:size 4 #:dock 'left)
       (lay 'tb
            (pane 'editor #:view eview #:size 3 #:dock 'center)
            (pane 'status #:view #f    #:size 1 #:dock 'bottom))))

;;; ════════════════ 命令（纯：ctx → (listof intent)） ════════════════

(define (insert! c text)
  (define v (ctx-view c))
  (if v (list (edit v (op-type text))) '()))

(define (edit-op! c op)
  (define v (ctx-view c))
  (if v (list (edit v op)) '()))

(define (nav! c f)
  (define v (ctx-view c))
  (if v (list (invoke (λ () (f v)))) '()))

(define (toggle-tree)
  (modify (λ (w)
            (define lay (world-layout w))
            (struct-copy world w
                         [layout (if (tree-visible? lay 'tree)
                                     (tree-hide lay 'tree)
                                     (tree-show lay 'tree))]))))

(define (stop) (modify (λ (w) (struct-copy world w [running? #f]))))

(define edit-keys
  (keys
   [(key 'left)      (λ (c) (nav! c view-left!))]
   [(key 'right)     (λ (c) (nav! c view-right!))]
   [(key 'up)        (λ (c) (nav! c view-up!))]
   [(key 'down)      (λ (c) (nav! c view-down!))]
   [(key 'home)      (λ (c) (nav! c view-home!))]
   [(key 'end)       (λ (c) (nav! c view-end!))]
   [(key 'enter)     (λ (c) (insert! c "\n"))]
   [(key 'backspace) (λ (c) (edit-op! c (op-backspace)))]
   [(key 'delete)    (λ (c) (edit-op! c (op-delete)))]))

(define global-keys
  (keys
   [(key 'b 'ctrl) (λ (c) (list (toggle-tree)))]
   [(key 't 'ctrl) (λ (c) (list (spawn 'demo (λ () (sleep 0.3) "async ok"))))]
   [(key 'x 'ctrl) (key 'c 'ctrl) (λ (c) (list (stop)))]))

;;; ════════════════ 世界 ════════════════

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable edit-keys global-keys pointer-keys)
              #:status "app-loop demo"))

;;; ════════════════ 交互 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "tui"))
      (run-app (make-app-world))
      (run-check!)))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))

(define (event-label ev)
  (cond [(key-event? ev)   (format "key ~a ~a" (key-event-key ev) (mods->list (key-event-mods ev)))]
        [(mouse-event? ev) (format "mouse ~a ~a" (mouse-event-action ev) (mouse-event-button ev))]
        [(app-event? ev)   (format "app ~a" (app-event-kind ev))]
        [else "?"]))

(define (feed! ev)
  (define-values (w intents) (world-step* (unbox world*) (list ev)))
  (set-box! world* w)
  (printf "  ~a  →  ~a\n" (event-label ev) (map intent-kind intents))
  intents)

(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

;; 合成事件：plain = 无修饰；ctrl = Ctrl+<key>
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))

(define (run-check!)
  (set-box! world* (make-app-world))
  (printf "初始：tree 可见=~a focus=editor? ~a\n"
          (tree-visible? (world-layout (unbox world*)) 'tree)
          (equal? (world-focus (unbox world*)) (leaf-ref 'editor)))

  ;; 纯 world 变换：C-b 开关 tree
  (feed! (ctrl 'b))
  (check "C-b 隐藏 tree" (not (tree-visible? (world-layout (unbox world*)) 'tree)))
  (feed! (ctrl 'b))
  (check "C-b 再显示 tree" (tree-visible? (world-layout (unbox world*)) 'tree))

  ;; 前缀序列：C-x 进 pending，C-x C-c 退出
  (feed! (ctrl 'x))
  (check "C-x 进入前缀" (equal? (world-pending (unbox world*)) (list (key 'x 'ctrl))))
  (feed! (ctrl 'c))
  (check "C-x C-c 停止" (not (world-running? (unbox world*))))

  ;; 可打印字符 → edit intent（step 纯，副作用留给 loop）
  (check "字符 → edit intent" (ormap edit? (feed! (plain #\Z))))

  ;; 异步：C-t → spawn intent（完成后进 inbox，下一事件时处理）
  (check "C-t → spawn intent" (ormap spawn? (feed! (ctrl 't))))

  ;; 内部事件：task-done 直接折进 status
  (define before (world-status (unbox world*)))
  (feed! (app-event 'task-done (list 'demo "42")))
  (check "task-done 更新 status" (not (equal? before (world-status (unbox world*)))))

  ;; 鼠标：点击编辑区落光标 + 起选
  ;; 先把 view 视口同步到本帧 panel 尺寸（headless 里没有 draw-world 做这件事）。
  (panels-sync! (world-panels (unbox world*)))
  (define ps (world-panels (unbox world*)))
  (define ep (for/first ([p (in-list ps)] #:when (eq? (panel-view p) eview)) p))
  (define cont (panel-content ep))
  (define sr (+ (rect-y cont) 1))
  (define sc (+ (rect-x cont) 2))
  (feed! (mouse-event 'press 'left (add1 sc) (add1 sr) (mods #f #f #f)))
  (check "点击切焦点到 editor" (equal? (world-focus (unbox world*)) (leaf-ref 'editor)))
  (define drag (world-drag (unbox world*)))
  (check "点击起选（drag=select）" (and (drag? drag) (eq? (drag-kind drag) 'select)))

  ;; 拖动 → select intent
  (define intents (feed! (mouse-event 'move #f (add1 (+ sc 3)) (add1 (+ sr 1)) (mods #f #f #f))))
  (check "拖动 → select intent" (ormap select? intents))
  (feed! (mouse-event 'release 'left (add1 (+ sc 3)) (add1 (+ sr 1)) (mods #f #f #f)))
  (check "释放清 drag" (not (world-drag (unbox world*))))

  ;; 拖缝：命中一条竖缝
  (define cuts (tree->cuts (world-layout (unbox world*)) (world-area (unbox world*))))
  (define vcut (for/first ([c (in-list cuts)] #:when (eq? (cut-axis c) 'lr)) c))
  (when vcut
    (define row (quotient (+ (cut-span-lo vcut) (cut-span-hi vcut)) 2))
    (feed! (mouse-event 'press 'left (add1 (cut-offset vcut)) (add1 row) (mods #f #f #f)))
    (check "点缝起拖" (and (drag? (world-drag (unbox world*)))
                          (eq? (drag-kind (world-drag (unbox world*))) 'seam)))
    (define lay0 (world-layout (unbox world*)))
    (feed! (mouse-event 'move #f (add1 (+ (cut-offset vcut) 4)) (add1 row) (mods #f #f #f)))
    (check "拖缝改变布局" (not (equal? lay0 (world-layout (unbox world*)))))
    (feed! (mouse-event 'release 'left (add1 (+ (cut-offset vcut) 4)) (add1 row) (mods #f #f #f))))

  (displayln "app loop demo: 自检 OK"))
