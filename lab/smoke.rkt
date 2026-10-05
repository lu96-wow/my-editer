#lang racket

;;; lab/smoke.rkt —— 骨架冒烟：确认 base / ui 的协议装得上、能跑通。
;;; 不测业务细节（那些在 smoke-app.rkt）。

(require rackunit
         "../core/editor.rkt"
         "base/input.rkt" "base/command.rkt" "base/dispatch.rkt"
         "base/layout/main.rkt"
         "ui/slot.rkt" "ui/mode.rkt"
         "app/edit-panes.rkt")

;;; ---------- input（事件 = racket-tui 规范事件；绑定键 = 匿名列表） ----------

(check-equal? (normalize-mods '(shift ctrl bogus)) '(ctrl shift))
(check-equal? (event->binding (key-event #\X (mods #t #f #f))) (key 'x 'ctrl))
(check-equal? (event->binding (key-event #\X (mods #t #f #t))) (key 'x 'ctrl 'shift))
(check-equal? (event->binding (key-event 'up no-mods)) (key 'up))
(check-equal? (event->binding (key-event #\a no-mods)) text-binding)      ; 无修饰字符 = 文本
(check-equal? (event->binding (key-event #\space no-mods)) text-binding)
(check-equal? (event->binding (paste-event #"hi" "hi")) paste-binding)
(check-equal? (event->binding (resize-event 10 20)) resize-binding)
(check-equal? (event->binding (mouse-event 'press 'left 3 4 no-mods)) (mouse 'press 'left))
(check-false (event->binding (null-event)))
;; 鼠标坐标 1-based → 0-based 屏幕格
(check-equal? (mouse-col (mouse-event 'press 'left 1 1 no-mods)) 0)
(check-equal? (mouse-row (mouse-event 'press 'left 1 1 no-mods)) 0)
(check-equal? (mouse-col (mouse-event 'press 'left 31 24 no-mods)) 30)
(check-equal? (mouse-row (mouse-event 'press 'left 31 24 no-mods)) 23)

;;; ---------- command ----------

(define calls (box '()))
(define (h tag) (lambda (e ctx) (set-box! calls (cons (list tag (event->binding e) ctx) (unbox calls)))))
(define (reset!) (set-box! calls '()))

(define global (command-table (key 'tab) (h 'g-tab) (key 'enter) (h 'g-enter)))
(define doc-t  (command-table (key 'enter) (h 'd-enter) (key 'backspace) (h 'd-bs)))
(define extra  (command-table (key 'enter) (h 'm-enter)))                 ; 模态表
(define cs (command-set-add-doc (command-set (list global)) 7 doc-t))

(check-equal? (command-set-tables cs 7) (list global doc-t))
(reset!)
(check-true (dispatch-run cs 7 '() (key-event 'enter no-mods) 'CTX))
(check-equal? (car (unbox calls)) '(d-enter (key enter ()) CTX))          ; did 表覆盖 global
(reset!)
(check-true (dispatch-run cs 7 '() (key-event 'tab no-mods) 'CTX))
(check-equal? (car (unbox calls)) '(g-tab (key tab ()) CTX))
(check-false (dispatch-run cs 9 '() (key-event 'backspace no-mods) 'CTX)) ; 别的 did 没这张表

;; 模态维度：extra-tables 接在 did 表之后、优先级最高
(check-equal? (length (dispatch-tables cs 7 (list extra))) 3)
(reset!)
(check-true (dispatch-run cs 7 (list extra) (key-event 'enter no-mods) 'CTX))
(check-equal? (car (unbox calls)) '(m-enter (key enter ()) CTX))

;;; ---------- layout ----------

(define (rects rs)
  (map (lambda (r) (list (rectangle-view-id r) (rectangle-x r) (rectangle-y r)
                         (rectangle-width r) (rectangle-height r)))
       rs))

(define main (regions-main (compute-regions 80 24)))             ; (24 0 56 23)
(define-values (ps bs ws) (tree->rectangles (node 'lr #f (leaf 0) (leaf 1)) main))
(check-equal? (rects ps) '((0 24 0 27 23) (1 52 0 28 23)))
(check-equal? (list (bar-x (car bs)) (bar-width (car bs))) '(51 1))   ; 中间 1 格分割条
(check-equal? ws '())

;; 左栏 / 底部条是预定义的，不占 split 树
(define lr (compute-layout (node 'lr #f (leaf 0) (leaf 1)) 80 24
                           #:left-vid 10 #:bottom-vid 11))
(check-equal? (map rectangle-view-id (layout-result-panes lr)) '(10 0 1 11))
(check-equal? (layout-vid-at lr 30 10) 0)
(check-equal? (layout-vid-at lr 30 23) 11)                        ; 底部条
(check-equal? (bar-x (layout-bar-at lr 51 10)) 51)
(check-equal? (layout-region-at lr 30 23) 'statusbar)
(check-equal? (layout-right lr 0) 1)
(check-equal? (layout-left lr 1) 0)

;; tree = #f：主区空（还没打开文档）
(define empty-main (compute-layout #f 80 24 #:left-vid 10 #:bottom-vid 11))
(check-equal? (map rectangle-view-id (layout-result-panes empty-main)) '(10 11))

;; 水平（tb）拆分也铺得出来
(define-values (ps2 _b2 _w2) (tree->rectangles (node 'tb #f (leaf 0) (leaf 1)) main))
(check-equal? (rects ps2) '((0 24 0 56 11) (1 24 12 56 11)))

;; 原地替换 leaf 内容（不改变结构）
(check-equal? (tree-replace (node 'tb #f (leaf 0) (leaf 1)) 1 9)
              (node 'tb #f (leaf 0) (leaf 9)))
(check-equal? (tree-vids (node 'lr #f (leaf 0) (leaf 1))) '(0 1))

;; 空间不足：不静默夹紧，输出 size-warning
(define tiny (compute-layout (node 'lr #f (leaf 0) (leaf 1)) 8 4
                             #:sidebar-width 0 #:statusbar-height 0))
(check-equal? (length (layout-result-warnings tiny)) 1)
(check-equal? (size-warning-dir (car (layout-result-warnings tiny))) 'lr)

;;; ---------- 输入转移状态：底部槽位（state / input）+ 续延回传 ----------

(define ed0 (editor-open "main" 56 23 "main"))                  ; vid 0
(define-values (ed1 _sd state-vid)
  (editor-add-document-view ed0 (state->document "1:1") 56 1 "*state*"))
(define-values (ed2 _id input-vid)
  (editor-add-document-view ed1 (input->document (input "new file: " #t)) 56 1 "*input*"))

(define mode (box #f))                                            ; #f | prompt
(define got (box 'none))

;; 发起：app 存 prompt、挂输入文档、底部切到 input
(define p (input-begin "new file: " #t 0 (lambda (v) (set-box! got v))))
(set-box! mode p)
(editor-view-assign! ed2 input-vid (prompt-document p ""))
(check-equal? (mode-bottom-vid (unbox mode) state-vid input-vid) input-vid)
(check-equal? (mode-focus-vid (unbox mode) input-vid) input-vid)

;; 输入
(editor-view-set-point! ed2 input-vid (point 0 (string-length "new file: ")))
(editor-view-insert! ed2 input-vid "created.txt")

;; 提交：app 先退出模态，再调续延
(define doc-string (editor-view-string ed2 input-vid))
(set-box! mode #f)
(input-commit p doc-string)
(check-equal? (unbox got) "created.txt")                          ; 值回传到发起方
(check-equal? (mode-bottom-vid (unbox mode) state-vid input-vid) state-vid)  ; 切回 state

;; 确认型：同一个 input 文档，on-commit 收 bool
(define got2 (box 'none))
(define p2 (input-begin "delete? (y/n)" #f 0 (lambda (yes) (set-box! got2 yes))))
(check-equal? (mode-bottom-vid p2 state-vid input-vid) input-vid)
(check-equal? (length (mode-tables p2 (command-table) (command-table))) 1)
(input-answer p2 #f)
(check-false (unbox got2))

;; 前缀（如 C-p）：不占 input，不动焦点，只叠自己的表
(define pf (prefix-begin "C-p" (list (command-table (key 'up) (lambda (e a) 'x)))))
(check-equal? (mode-bottom-vid pf state-vid input-vid) state-vid)
(check-false (mode-focus-vid pf input-vid))
(check-equal? (length (mode-tables pf (command-table) (command-table))) 1)

;; 底部槽位：布局的 bottom-vid 也随模式切换
(define lay (compute-layout (leaf 0) 80 24 #:left-vid #f #:bottom-vid input-vid))
(check-equal? (layout-vid-at lay 30 23) input-vid)

;;; ---------- edit-panes：编辑区分屏树 + active ----------

(define ep (edit-panes-empty))
(check-false (edit-panes-tree ep))
(check-false (edit-panes-active ep))
(edit-panes-open! ep 5)
(check-equal? (edit-panes-tree ep) (leaf 5))
(check-equal? (edit-panes-active ep) 5)
(edit-panes-open! ep 6)                                   ; 无分屏时=替换 active
(check-equal? (edit-panes-tree ep) (leaf 6))

;; 两个 leaf：open 只换 active，remove 只删对应 leaf
(define ep2 (edit-panes (node 'lr #f (leaf 1) (leaf 2)) 2))
(edit-panes-open! ep2 9)
(check-equal? (edit-panes-tree ep2) (node 'lr #f (leaf 1) (leaf 9)))
(check-equal? (edit-panes-active ep2) 9)
(edit-panes-remove! ep2 (list 9))
(check-equal? (edit-panes-tree ep2) (leaf 1))
(check-equal? (edit-panes-active ep2) 1)                  ; active 被删 → 回落
(edit-panes-remove! ep2 (list 1))
(check-false (edit-panes-tree ep2))
(check-false (edit-panes-active ep2))

(displayln "lab smoke: ok")
