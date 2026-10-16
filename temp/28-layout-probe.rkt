#lang racket

;;; 28 —— 布局数据层探针（诊断用，headless）
;;;
;;;   racket temp/28-layout-probe.rkt
;;;
;;; 检查：
;;;   · 布局树 / placements / panels / refs 的数据是否一致；
;;;   · 坐标基准：core 全部 0-based（row,col），racket-tui 是 1-based，换算是 mouse-position 减 1；
;;;   · panel-at 命中与 ref 反查是否对得上；
;;;   · 切分（tree-split / ops split-*）在数据层是否正常（leaf 数、rect、role、焦点）。

(require tui
         "../core/editor.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 造和 demo 一样的 world ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'file-tree #:keymaps '())
(define-doc-kind! 'status #:keymaps '())

(define res (make-resources))
(define-values (tb tview) (open-document! res "*tree*" "src/\n  main.rkt\n" #:kind 'file-tree))
(define-values (eb eview) (open-document! res "main.rkt" "(f 41)\n" #:kind 'text))
(define-values (sb sview) (open-document! res "*status*" " status" #:kind 'status))

(define W 80) (define H 24)
(define (base-layout)
  (lay 'tb
       (pane 'tree   #:view tview #:size 1 #:dock 'top)
       (pane 'editor #:view eview #:size 8 #:dock 'center #:role 'editor)
       (pane 'status #:view sview #:size 1 #:borders '())))

(define (make-w)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable)))

;;; ════════════════ 打印工具 ════════════════

(define (show-tree t [ind ""])
  (cond
    [(leaf? t)
     (printf "~a leaf ~a role=~a size=~a view=~a\n"
             ind (leaf-id t) (leaf-role t) (leaf-size t)
             (if (leaf-view t) "有" "#f"))]
    [else
     (printf "~a split ~a size=~a\n" ind (split-axis t) (split-size t))
     (for ([c (in-list (split-children t))]) (show-tree c (string-append ind "  ")))]))

(define (hline s) (printf "\n=== ~a ===\n" s))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (printf "  �’ ~a 失败\n" label)))

;;; ════════════════ 探针 ════════════════

(define w (make-w))
(define area (world-area w))

(hline "布局树")
(show-tree (world-layout w))

(hline "placements（id → rect 0-based）")
(define pls (tree->placements (world-layout w) area))
(for ([pl (in-list pls)])
  (printf "  ~a  x=~a y=~a w=~a h=~a\n" (car pl) (rect-x (cadr pl)) (rect-y (cadr pl))
          (rect-w (cadr pl)) (rect-h (cadr pl))))

(hline "panels / refs（应同序、同长）")
(define ps (world-panels w))
(define refs (world-panel-refs w))
(printf "  panels=~a refs=~a\n" (length ps) (length refs))
(for ([p (in-list ps)] [r (in-list refs)])
  (printf "  ref=~a kind=~a id=~a  panel rect x=~a y=~a w=~a h=~a view=~a\n"
          r (panel-ref-kind r) (panel-ref-id r)
          (rect-x (panel-rect p)) (rect-y (panel-rect p))
          (rect-w (panel-rect p)) (rect-h (panel-rect p))
          (if (panel-view p) "有" "#f")))
(check "panels 与 refs 同长" (= (length ps) (length refs)))

(hline "坐标 / 命中（core 0-based）")
;; 取 editor 的 rect，命中它内部一点 (row=y+1, col=x+1)
(define er (cadr (assoc 'editor pls)))
(define hit-row (+ (rect-y er) 1))
(define hit-col (+ (rect-x er) 1))
(define hit (panel-at ps hit-row hit-col))
(define hit-ref (panel->ref ps refs hit))
(printf "  命中 (row=~a,col=~a) → ref=~a\n" hit-row hit-col hit-ref)
(check "panel-at 命中 editor" (equal? hit-ref (leaf-ref 'editor)))
;; racket-tui 鼠标是 1-based：构造 (x=col+1, y=row+1) → mouse-position 应还原 0-based
(define mev (mouse-event 'press 'left (add1 hit-col) (add1 hit-row) (mods #f #f #f)))
(define-values (mrow mcol) (mouse-position mev))
(printf "  mouse(x=~a,y=~a) → (row=~a,col=~a)\n" (mouse-event-x mev) (mouse-event-y mev) mrow mcol)
(check "1-based 鼠标坐标 → 0-based 对得上" (and (= mrow hit-row) (= mcol hit-col)))

(hline "ref → view/panel 解析")
(check "ref->view(editor) = eview" (eq? (world-ref->view w (leaf-ref 'editor)) eview))
(check "ref->panel(editor) 有" (and (world-ref->panel w (leaf-ref 'editor)) #t))
(check "ref->view(不存在) = #f" (not (world-ref->view w (leaf-ref 'nope))))

(hline "数据层切分：ops split-right（喂合成事件走 app）")
(define (feed! ev)
  (define-values (w2 intents) (world-step* w (list ev))) (set! w w2) intents)
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c) (key-event c (mods #t #f #f)))
;; 临时给 global 表：C-s + right
(set! w (struct-copy world w
                     [keytable (make-keytable
                                (keys [(key 's 'ctrl) (key 'right) (λ (ctx) (split-right ctx))]))]))
(define n0 (length (tree-leaves (world-layout w))))
(feed! (ctrl 's)) (feed! (plain 'right))
(define n1 (length (tree-leaves (world-layout w))))
(printf "  切分前 leaf=~a，切分后 leaf=~a\n" n0 n1)
(check "split-right 多一个 leaf" (= n1 (add1 n0)))
(define fref (world-focus w))
(define fl (and (eq? (panel-ref-kind fref) 'leaf) (tree-find (world-layout w) (panel-ref-id fref))))
(printf "  焦点 ref=~a role=~a view=~a\n"
        fref (and fl (leaf-role fl)) (and fl (if (leaf-view fl) "有" "#f")))
(check "新 leaf role='editor" (eq? (leaf-role fl) 'editor))
(check "新 leaf 为空（view=#f）" (not (leaf-view fl)))
(check "焦点在新 leaf" (equal? fref (world-focus w)))

(hline "切分后 placements（新的编辑区应有独立 rect）")
(for ([pl (in-list (tree->placements (world-layout w) (world-area w)))])
  (printf "  ~a  x=~a y=~a w=~a h=~a\n" (car pl) (rect-x (cadr pl)) (rect-y (cadr pl))
          (rect-w (cadr pl)) (rect-h (cadr pl))))

(printf "\nprobe done\n")
