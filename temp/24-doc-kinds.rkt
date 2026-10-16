#lang racket

;;; 24 —— document 类型 → 命令表 绑定（穿透 focus）+ 资源管理
;;;
;;;   racket temp/24-doc-kinds.rkt         # headless：验证“换焦点就换表”
;;;   racket temp/24-doc-kinds.rkt tui     # 交互
;;;
;;; 演示：
;;;   · 两个 document 类型：'text（edit+motion 合并）、'file-tree（自定义小表）；
;;;   · 资源管理 open-document! 创建并给 document 绑类型；
;;;   · 焦点在哪个 view，命令表就换成该 document 类型的表（不用改 step）；
;;;   · per-document 追加 / 拔出表层（插件覆盖 / 还原）；
;;;   · C-n 通过 open-doc intent 运行期新开一个 document+view 装进布局。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 类型：两张基础表合并成 text；自定义 file-tree ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))

;; 文件树文档自己的命令表（左/右/回车/点击语义完全不同于文本）
(define tree-keys
  (keys
   [(key 'left)  (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "tree: collapse"])))))]
   [(key 'right) (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "tree: expand"])))))]
   [(key 'enter) (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "tree: open"])))))]
   [(mouse 'press 'left) (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "tree: click node"])))))]))
(define-doc-kind! 'file-tree #:keymaps (list tree-keys))

;;; ════════════════ 资源管理：造 document+view ════════════════

(define res (make-resources))

(define-values (eb eview) (open-document! res "main.rkt"
                                          "(define (f x)\n  (+ x 1))\n\n(f 41)\n"
                                          #:kind 'text))
(define-values (tb tview) (open-document! res "*tree*"
                                          "src/\n  main.rkt\n  util.rkt\nREADME.md"
                                          #:kind 'file-tree))

(define W 80) (define H 24)

(define (base-layout)
  (lay 'lr
       (pane 'tree   #:view tview #:size 3 #:dock 'left)
       (pane 'editor #:view eview #:size 5 #:dock 'center)
       (pane 'aux    #:view #f    #:size 2 #:dock 'right)))

;;; ════════════════ 全局命令（含运行期 open-doc） ════════════════

(define (toggle-tree)
  (modify (λ (w)
            (define lay (world-layout w))
            (struct-copy world w
                         [layout (if (tree-visible? lay 'tree)
                                     (tree-hide lay 'tree)
                                     (tree-show lay 'tree))]))))

(define global-keys
  (keys
   [(key 'b 'ctrl) (λ (ctx) (list (toggle-tree)))]
   [(key 'x 'ctrl) (key 'c 'ctrl) (λ (ctx) (quit))]
   ;; 运行期打开：open-doc = 不纯创建（解释器）+ 纯 world 变换（装进布局 / 切焦点）
   [(key 'n 'ctrl)
    (λ (ctx)
      (list (open-doc
             (λ () (open-document! res "untitled" "" #:kind 'text))
             (λ (w b v)
               (define w1 (world-focus-on w (leaf-ref 'aux)))
               (struct-copy world w1
                            [layout (tree-set-view (world-layout w) 'aux v)])))))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys focus-keys)
              #:status "doc-kinds demo"))

;;; ════════════════ 交互 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "tui"))
      (run-app (make-app-world))
      (run-check!)))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

(define (feed! ev)
  (define-values (w intents) (world-step* (unbox world*) (list ev)))
  (set-box! world* w)
  (printf "  focus=~a  →  intents=~a  status=~a\n"
          (cond [(equal? (world-focus w) (leaf-ref 'editor)) "editor"]
                [(equal? (world-focus w) (leaf-ref 'tree)) "tree"]
                [else "other"])
          (map intent-kind intents) (world-status w))
  intents)

(define (run-check!)
  (set-box! world* (make-app-world))
  (printf "已打开资源：~a\n" (map buffer-name (resources-list res)))
  (check "资源登记 2 个 document" (= 2 (length (resources-list res))))
  (check "eview 类型 = text" (eq? (view-kind eview) 'text))
  (check "tview 类型 = file-tree" (eq? (view-kind tview) 'file-tree))

  ;; 焦点在 editor（text kind）：left 走 motion-keys → invoke
  (check "焦点 editor + left → motion(invoke)"
         (ormap invoke? (feed! (plain 'left))))

  ;; 换焦点到 tree（file-tree kind）：同一次 left 走 tree-keys → 改 status
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'tree)]))
  (feed! (plain 'left))
  (check "焦点 tree + left → tree: collapse" (equal? (world-status (unbox world*)) "tree: collapse"))
  (feed! (plain 'right))
  (check "焦点 tree + right → tree: expand" (equal? (world-status (unbox world*)) "tree: expand"))

  ;; 回到 editor，再确认走回 text 表
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'editor)]))
  (check "焦点 editor + left → 回到 motion(invoke)"
         (ormap invoke? (feed! (plain 'left))))

  ;; per-document 覆盖层：给 editor buffer 追加一层，left 被覆盖
  (define override
    (keys [(key 'left) (λ (ctx) (list (modify (λ (w) (struct-copy world w [status "override: left"])))))]))
  (buffer-add-keytable! (view-buffer eview) (make-keytable override))
  (feed! (plain 'left))
  (check "per-document 覆盖 left" (equal? (world-status (unbox world*)) "override: left"))
  (buffer-remove-keytable! (view-buffer eview) (make-keytable override))
  (check "拔出覆盖层后 left 还原 motion"
         (ormap invoke? (feed! (plain 'left))))

  ;; —— 鼠标行为按 document 类型分派（③）——
  (panels-sync! (world-panels (unbox world*)))
  (define (panel-of v)
    (for/first ([p (in-list (world-panels (unbox world*)))] #:when (eq? (panel-view p) v)) p))
  (define (click! v)
    (define c (panel-content (panel-of v)))
    (feed! (mouse-event 'press 'left (add1 (+ (rect-x c) 1)) (add1 (+ (rect-y c) 1)) (mods #f #f #f))))
  ;; 焦点 tree：点击走 tree 类型命令
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'tree)]))
  (click! tview)
  (check "tree 类型：点击 → tree: click node" (equal? (world-status (unbox world*)) "tree: click node"))
  (check "tree 类型：点击聚焦 tree" (equal? (world-focus (unbox world*)) (leaf-ref 'tree)))
  ;; 点 editor：走 text 类型的 pointer-keys（聚焦 + 落点 + 起选）
  (click! eview)
  (check "editor 类型：点击聚焦 editor" (equal? (world-focus (unbox world*)) (leaf-ref 'editor)))
  (check "editor 类型：点击起选（drag=select）"
         (and (drag? (world-drag (unbox world*)))
              (eq? (drag-kind (world-drag (unbox world*))) 'select)))

  ;; 运行期 open-doc：C-n → open-doc intent；手动跑解释器两步（make 造，f 装）
  (define intents (feed! (ctrl 'n)))
  (define od (for/first ([i (in-list intents)] #:when (open-doc? i)) i))
  (check "C-n → open-doc intent" (and od #t))
  (when od
    (define-values (b v) ((open-doc-make od)))
    (define w* ((open-doc-f od) (unbox world*) b v))
    (set-box! world* w*)
    (check "open-doc：新 view 装进 aux"
           (eq? (leaf-view (tree-find (world-layout w*) 'aux)) v))
    (check "open-doc：焦点切到新 view" (eq? (world-focus-view w*) v))
    (check "open-doc：新 document 绑 text" (eq? (view-kind v) 'text)))

  ;; —— ④ 引用稳定性：把聚焦 leaf 的 view 换成另一份 document ——
  ;; 焦点是 leaf-ref（不是 view 值），所以替换后不悬空，且命令表随新 document 类型切换。
  (define-values (_b4 ev4) (open-document! res "replaced" "n\n" #:kind 'file-tree))
  (set-box! world*
            (struct-copy world (unbox world*)
                         [layout (tree-set-view (world-layout (unbox world*)) 'editor ev4)]
                         [focus (leaf-ref 'editor)]))
  (check "④ 替换 view：焦点 ref 不变，解析到同 leaf 的新 view"
         (eq? (world-focus-view (unbox world*)) ev4))
  (feed! (plain 'left))
  (check "④ 替换 view：命令表随新 document 类型切换"
         (equal? (world-status (unbox world*)) "tree: collapse"))

  ;; —— focus-keys：键盘在面板间移动焦点（与文档类型无关）——
  (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref 'tree)]))
  (feed! (ctrl 'w)) (feed! (plain 'right))
  (check "focus-keys：C-w → 焦点移到 editor"
         (equal? (world-focus (unbox world*)) (leaf-ref 'editor)))
  (feed! (ctrl 'w)) (feed! (plain 'left))
  (check "focus-keys：C-w ← 焦点移回 tree"
         (equal? (world-focus (unbox world*)) (leaf-ref 'tree)))

  (displayln "doc-kinds demo: 自检 OK"))
