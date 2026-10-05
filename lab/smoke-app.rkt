#lang racket

;;; lab-rebuild/smoke-app.rkt —— app 集成冒烟（无终端）：模拟 racket-tui 事件，验证
;;; 文件树打开 / minibuffer 新建 / 输入转移 / 焦点 / 增删同步。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "base/input.rkt"
         "command/table.rkt"
         "base/layout/main.rkt"
         "ui/tree.rkt"
         "ui/buffers.rkt"
         "ui/mode.rkt"
         "app/app.rkt"
         "core/state.rkt"
         "core/panes.rkt"
         "core/edit-panes.rkt"
         "core/actions.rkt"
         "core/paths.rkt"
         "plugin/seam.rkt"
         "base/face.rkt")

(define root (simplify-path (path->complete-path (make-temporary-file "app~a" 'directory))))
(with-output-to-file (build-path root "aaa.txt") #:exists 'replace (lambda () (display "AAA")))
(with-output-to-file (build-path root "bbb.txt") #:exists 'replace (lambda () (display "BBB")))
(make-directory (build-path root "sub"))
(with-output-to-file (build-path root "sub" "inner.txt") #:exists 'replace (lambda () (display "INNER")))

(define a (app-init root 80 24 #:sidebar-width 24))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))
(define (tree-vid) (panes-tree (app-panes a)))
(define (bufs-vid) (panes-bufs (app-panes a)))
(define (edit-vid) (app-edit-active a))
(define (state-vid) (panes-state (app-panes a)))
(define (input-vid) (panes-input (app-panes a)))
(define (tree-line-of name)
  (for/first ([e (in-list (tree-entries (app-tree a)))] [i (in-naturals)]
              #:when (equal? (entry-name e) name)) i))

;;; ---------- 初始化 / 布局 / 渲染 ----------

(check-equal? (app-focus a) (tree-vid))
(void (app-prepare! a))
(check-not-false (string-contains? (editor-view-string (ed) (state-vid)) "tree"))
(check-false (edit-vid))                                   ; 不预开文档：主区空
(define panes (layout-result-panes (app-layout-result a)))
(check-equal? (map rectangle-view-id panes) (list (tree-vid) (state-vid)))

;; Ctrl+B：没有编辑窗格时关左栏 → 焦点置空（不放到底部 state）
(send (key-event 'b (mods #t #f #f)))
(check-false (app-sidebar? a))
(check-false (app-focus a))
(check-equal? (map rectangle-view-id (layout-result-panes (app-layout-result a))) (list (state-vid)))
(send (key-event 'b (mods #t #f #f)))                      ; 开回来
(check-true (app-sidebar? a))
(check-equal? (app-focus a) (tree-vid))
(define scr (app-render a))
(check-equal? (screen-width scr) 80)
(check-equal? (screen-height scr) 24)
;; tui 的增量渲染路径也不崩
(define-values (scr2 render selection)
  (editor-render-layout-patch (ed) #f panes (app-focus a) 80 24))
(check-true (screen? scr2))
(check-true (list? (append render selection)))

;;; ---------- 树：←/→ 是光标移动；Enter 开关目录 ----------

(define dline (tree-line-of "sub"))
(check-true (exact-nonnegative-integer? dline))
(editor-view-set-point! (ed) (tree-vid) (point dline 0))
(define n0 (length (tree-entries (app-tree a))))
(send (key-event 'enter no-mods))                          ; 展开
(check-true (> (length (tree-entries (app-tree a))) n0))
(send (key-event 'right no-mods))                          ; 光标右移，不折叠
(check-true (> (length (tree-entries (app-tree a))) n0))
(check-true (> (editor-view-point-column (ed) (tree-vid)) 0))
(send (key-event 'left no-mods))
(check-equal? (editor-view-point-column (ed) (tree-vid)) 0)
(send (key-event 'enter no-mods))                          ; 再 Enter 折叠
(check-equal? (length (tree-entries (app-tree a))) n0)

;;; ---------- 树：Enter 打开文件（懒建编辑视图，焦点留在树） ----------

(send (key-event 'p (mods #t #f #f)))                      ; C-p 前缀
(send (key-event 'right no-mods))                          ; 主区空 → 焦点不动
(check-equal? (app-focus a) (tree-vid))
(check-false (app-mode a))                                 ; 前缀用完即退

(define l (tree-line-of "aaa.txt"))
(check-true (exact-nonnegative-integer? l))
(editor-view-set-point! (ed) (tree-vid) (point l 0))
(send (key-event 'enter no-mods))
(check-true (and (edit-vid) #t))
(check-equal? (app-focus a) (tree-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")

;;; ---------- 焦点移动（C-p 前缀 + 方向）：主区出现后可用；state 行三段 ----------

(send (key-event 'p (mods #t #f #f)))                      ; C-p 前缀
(check-true (prefix? (app-mode a)))                        ; 进入前缀
(void (app-prepare! a))
(check-not-false (string-contains? (editor-view-string (ed) (state-vid)) "[C-p-]"))
(send (key-event 'right no-mods))                          ; C-p right → 到编辑格
(check-false (app-mode a))                                 ; 前缀退出
(check-equal? (app-focus a) (edit-vid))
(void (app-prepare! a))
(define state-text (editor-view-string (ed) (state-vid)))
(check-not-false (string-contains? state-text "edit"))         ; 焦点
(check-not-false (string-contains? state-text "1:1"))          ; 行:列
(check-not-false (string-contains? state-text "aaa.txt"))      ; view 对应 document 的文件名
;; 前缀里非方向键不回落 normal（类 Emacs）：C-p 后按字符不会插入
(define before-prefix (editor-view-string (ed) (edit-vid)))
(send (key-event 'p (mods #t #f #f)))
(send (key-event #\Z no-mods))
(check-equal? (editor-view-string (ed) (edit-vid)) before-prefix)
(check-false (app-mode a))
(send (key-event 'p (mods #t #f #f)))
(send (key-event 'left no-mods))                           ; C-p left → 回树
(check-equal? (app-focus a) (tree-vid))

;;; ---------- minibuffer：Ctrl+N 新建文件（模态表走 dispatch） ----------

(check-equal? (app-focus a) (tree-vid))
(editor-view-set-point! (ed) (tree-vid) (point 0 0))       ; 根
(send (key-event 'n (mods #t #f #f)))                      ; 发起输入
(check-true (and (app-mode a) #t))
(check-equal? (app-focus a) (input-vid))
(check-equal? (app-bottom-vid a) (input-vid))
(check-equal? (editor-view-string (ed) (input-vid)) "new file: ")
(for ([c (in-string "made.txt")]) (send (key-event c no-mods)))
(check-equal? (editor-view-string (ed) (input-vid)) "new file: made.txt")
(send (key-event 'enter no-mods))
(check-false (app-mode a))
(check-equal? (app-focus a) (tree-vid))
(check-true (file-exists? (build-path root "made.txt")))
(check-equal? (app-bottom-vid a) (state-vid))

;;; ---------- minibuffer：Esc 取消 ----------

(send (key-event 'l (mods #t #f #f)))                      ; Ctrl+L 新建目录
(check-true (and (app-mode a) #t))
(send (key-event 'escape no-mods))
(check-false (app-mode a))
(check-false (directory-exists? (build-path root "nomake")))

;;; ---------- 树只读：输入以外不落字符 ----------

(check-equal? (app-focus a) (tree-vid))
(editor-view-set-point! (ed) (tree-vid) (point 0 1000))
(define before (editor-view-string (ed) (tree-vid)))
(send (key-event #\Z no-mods))                             ; 无修饰字符 = text
(check-equal? (editor-view-string (ed) (tree-vid)) before)

;;; ---------- 确认型 prompt 复用同一个 input 文档 ----------

(define dl (tree-line-of "aaa.txt"))
(check-true (exact-nonnegative-integer? dl))
(editor-view-set-point! (ed) (tree-vid) (point dl 0))
(send (key-event 'backspace no-mods))                      ; 删除确认（y/n）
(check-true (and (app-mode a) (not (prompt-editable? (app-mode a)))))
(check-equal? (app-focus a) (input-vid))
(check-equal? (app-bottom-vid a) (input-vid))
(check-not-false (string-contains? (editor-view-string (ed) (input-vid)) "delete"))
(send (key-event #\n no-mods))                             ; n = 不删
(check-false (app-mode a))
(check-true (file-exists? (build-path root "aaa.txt")))
(check-equal? (app-focus a) (tree-vid))

;;; ---------- 左侧 Tab 切换 + 文档 / 视图列表 ----------

;;; ---------- Ctrl+B：开 / 关左侧视图 ----------

(check-equal? (app-focus a) (tree-vid))
(check-true (app-sidebar? a))
(send (key-event 'b (mods #t #f #f)))                     ; 关左栏 → 焦点到编辑格
(check-false (app-sidebar? a))
(check-equal? (app-focus a) (edit-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")
(check-not-false (memv (edit-vid) (map rectangle-view-id (layout-result-panes (app-layout-result a)))))
(check-false (memv (tree-vid) (map rectangle-view-id (layout-result-panes (app-layout-result a)))))
(send (key-event 'b (mods #t #f #f)))                     ; 开左栏 → 焦点回左栏
(check-true (app-sidebar? a))
(check-equal? (app-focus a) (tree-vid))
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'bufs)
(check-equal? (app-focus a) (bufs-vid))
(check-equal? (rectangle-view-id (car (layout-result-panes (app-layout-result a))))
              (bufs-vid))
(define bufs-text (editor-view-string (ed) (bufs-vid)))
(check-false (string-contains? bufs-text "*scratch*"))
(check-false (string-contains? bufs-text "*state*"))
(check-not-false (string-contains? bufs-text "aaa.txt"))

;; 展开 aaa.txt 的 doc 行 → 出现 view 行；选 view 行 Enter 打开到编辑格
(define (buf-line pred)
  (for/first ([s (in-list (string-split (editor-view-string (ed) (bufs-vid)) "\n"))]
              [i (in-naturals)] #:when (pred s)) i))
(editor-view-set-point! (ed) (bufs-vid) (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
(send (key-event 'enter no-mods))
(check-not-false (string-contains? (editor-view-string (ed) (bufs-vid)) "view"))
(editor-view-set-point! (ed) (bufs-vid)
                        (point (buf-line (lambda (s) (string-contains? s "view"))) 0))
(send (key-event 'enter no-mods))
(check-equal? (app-focus a) (edit-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")

;; 再切回文件树
(set-app-focus! a (bufs-vid))                              ; 焦点回左栏
(check-equal? (app-focus a) (bufs-vid))
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'tree)
(check-equal? (app-focus a) (tree-vid))

;;; ---------- 鼠标：输入时点别处取消；点输入行定位 ----------

(editor-view-set-point! (ed) (tree-vid) (point 0 0))
(send (key-event 'n (mods #t #f #f)))                     ; 打开输入
(check-true (and (app-mode a) #t))
(send (mouse-event 'press 'left 31 11 no-mods))           ; 点在编辑区（1-based）→ 取消
(check-false (app-mode a))

(send (key-event 'n (mods #t #f #f)))                     ; 再开
(send (mouse-event 'press 'left 31 24 no-mods))           ; 点输入行自身（1-based）
(check-true (and (app-mode a) #t))                        ; 不取消
(check-equal? (app-focus a) (input-vid))
;; 1-based (31,24) → 0-based 屏幕格 (30,23) → 输入视图内列 30-24 = 6
(check-equal? (editor-view-point-column (ed) (input-vid)) 6)
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;; 正常模式：点编辑区聚焦
(send (mouse-event 'press 'left 41 6 no-mods))
(check-equal? (app-focus a) (edit-vid))

;;; ---------- 删除已打开的文件：同步关闭文档 / 视图 ----------

(set-app-focus! a (tree-vid))                              ; 回左栏
(check-equal? (app-focus a) (tree-vid))
(editor-view-set-point! (ed) (tree-vid) (point 0 0))       ; 根
(send (key-event 'n (mods #t #f #f)))                     ; Ctrl+N 新建 gone.txt
(for ([c (in-string "gone.txt")]) (send (key-event c no-mods)))
(send (key-event 'enter no-mods))
(check-true (file-exists? (build-path root "gone.txt")))
(editor-view-set-point! (ed) (tree-vid) (point (tree-line-of "gone.txt") 0))
(send (key-event 'enter no-mods))                          ; 打开（焦点仍在树）
(check-equal? (app-focus a) (tree-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "")
(send (key-event 'backspace no-mods))                      ; 删除确认
(check-true (and (app-mode a) (not (prompt-editable? (app-mode a)))))
(send (key-event #\y no-mods))
(check-false (app-mode a))
(check-false (file-exists? (build-path root "gone.txt")))
(check-false (path-table-did (app-paths a) (build-path root "gone.txt")))
;; 编辑格改显下一个还开着的 aaa.txt，文档列表里 gone.txt 也没了
(check-true (and (edit-vid) #t))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")
(check-false (string-contains? (editor-view-string (ed) (bufs-vid)) "gone.txt"))

;;; ---------- 删除目录：连带关闭目录下已打开的文档 ----------

(define subpath (simplify-path (build-path root "sub")))
(unless (tree-expanded? (app-tree a) subpath)
  (editor-view-set-point! (ed) (tree-vid) (point (tree-line-of "sub") 0))
  (send (key-event 'enter no-mods)))                       ; 展开 sub
(editor-view-set-point! (ed) (tree-vid) (point (tree-line-of "inner.txt") 0))
(send (key-event 'enter no-mods))                          ; 打开 sub/inner.txt
(check-equal? (editor-view-string (ed) (edit-vid)) "INNER")
(editor-view-set-point! (ed) (tree-vid) (point (tree-line-of "sub") 0))
(send (key-event 'backspace no-mods))                      ; 删目录
(send (key-event #\y no-mods))
(check-false (directory-exists? (build-path root "sub")))
(check-false (path-table-did (app-paths a) (build-path root "sub" "inner.txt")))
(check-false (string-contains? (editor-view-string (ed) (bufs-vid)) "inner.txt"))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")  ; 回落到 aaa.txt

;;; ---------- 文档列表：Backspace 关闭视图 / 文档 ----------

(send (key-event 'tab no-mods))                            ; 切到文档列表
(check-equal? (app-left a) 'bufs)
(check-equal? (app-focus a) (bufs-vid))

;; 展开 aaa.txt 的 doc 行 → view 行（前面可能已展开过）
(define aaa-did (path-table-did (app-paths a) (build-path root "aaa.txt")))
(unless (buffers-expanded? (app-bufs a) aaa-did)
  (editor-view-set-point! (ed) (bufs-vid) (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
  (send (key-event 'enter no-mods)))
(check-not-false (string-contains? (editor-view-string (ed) (bufs-vid)) "view"))

;; Ctrl+N：光标在 doc 行 → 给该文档再开一个 view
(define (view-row-count)
  (for/sum ([s (in-list (string-split (editor-view-string (ed) (bufs-vid)) "\n"))]
            #:when (string-contains? s "view"))
    1))
(editor-view-set-point! (ed) (bufs-vid) (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
(check-equal? (view-row-count) 1)
(send (key-event 'n (mods #t #f #f)))                      ; Ctrl+N 新建 view
(check-equal? (view-row-count) 2)

;; 手工分屏：编辑区换成两叶树 → app 一次铺出两个编辑窗格（为后续拆分命令铺路）
(define aaa-views (editor-document-view-list (ed) aaa-did))
(check-equal? (length aaa-views) 2)
(set-edit-panes-tree! (app-edit a) (node 'lr #f (leaf (first aaa-views)) (leaf (second aaa-views))))
(set-edit-panes-active! (app-edit a) (first aaa-views))
(app-invalidate-layout! a)
(define split-ids (map rectangle-view-id (layout-result-panes (app-layout-result a))))
(check-true (and (memv (first aaa-views) split-ids) (memv (second aaa-views) split-ids) #t))
(void (app-render a))                                       ; 多窗格渲染不崩
;; 还原成单窗格，继续后面的关闭用例
(set-edit-panes-tree! (app-edit a) (leaf (first aaa-views)))
(set-edit-panes-active! (app-edit a) (first aaa-views))
(app-invalidate-layout! a)

;; 关一个 view → 还剩一个，文档保留
(editor-view-set-point! (ed) (bufs-vid)
                        (point (buf-line (lambda (s) (string-contains? s "view"))) 0))
(send (key-event 'backspace no-mods))
(check-equal? (view-row-count) 1)
(check-not-false (path-table-did (app-paths a) (build-path root "aaa.txt")))

;; 再关最后一个 view → 文档仍保留，只是变成没有 view
(editor-view-set-point! (ed) (bufs-vid)
                        (point (buf-line (lambda (s) (string-contains? s "view"))) 0))
(send (key-event 'backspace no-mods))
(check-equal? (view-row-count) 0)
(check-not-false (path-table-did (app-paths a) (build-path root "aaa.txt")))   ; 文档还在
(check-not-false (string-contains? (editor-view-string (ed) (bufs-vid)) "aaa.txt"))
(check-false (edit-vid))                                   ; 没有 view 可显示了

;; doc 行 Backspace：关文档（连带所有 view）
(editor-view-set-point! (ed) (bufs-vid)
                        (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
(send (key-event 'backspace no-mods))
(check-false (path-table-did (app-paths a) (build-path root "aaa.txt")))
(check-false (string-contains? (editor-view-string (ed) (bufs-vid)) "aaa.txt"))

;;; ---------- 退出 ----------

(send (key-event 'q (mods #t #f #f)))
(check-true (app-quit? a))

;;; ---------- 编辑区分屏：Ctrl+K/L 分，Ctrl+D 关窗格 ----------

(define root2 (simplify-path (path->complete-path (make-temporary-file "split~a" 'directory))))
(with-output-to-file (build-path root2 "one.txt") #:exists 'replace (lambda () (display "ONE")))
(define b (app-init root2 80 24 #:sidebar-width 24))
(define (send2 e) (app-handle-input b e))
(define (b-ed) (app-ed b))
(define (b-tree) (panes-tree (app-panes b)))
(define (b-edit) (app-edit-active b))
;; 当前编辑区里显示的窗格 vid（按树里的顺序）
(define (main-panes)
  (for/list ([r (in-list (layout-result-panes (app-layout-result b)))]
             #:when (memv (rectangle-view-id r) (tree-vids (app-edit-tree b))))
    (rectangle-view-id r)))

(define ol (for/first ([e (in-list (tree-entries (app-tree b)))] [i (in-naturals)]
                       #:when (equal? (entry-name e) "one.txt")) i))
(editor-view-set-point! (b-ed) (b-tree) (point ol 0))
(send2 (key-event 'enter no-mods))
(check-equal? (editor-view-string (b-ed) (b-edit)) "ONE")
(check-equal? (length (main-panes)) 1)

;; Ctrl+K：水平分隔（上下）——拆 active 窗格
(send2 (key-event 'k (mods #t #f #f)))
(check-equal? (length (main-panes)) 2)
(check-true (node? (app-edit-tree b)))
(check-equal? (node-dir (app-edit-tree b)) 'tb)
(check-equal? (app-edit-active b) (b-edit))               ; active 转到新窗格
(check-not-false (string-contains? (screen->string (app-render b)) "─"))  ; 水平分隔线

;; 上下窗格：Ctrl+↑/↓ 移焦点
(define tv (car (tree-vids (app-edit-tree b))))
(define bv (cadr (tree-vids (app-edit-tree b))))
(check-equal? (app-focus b) bv)
;; C-p 前缀 + ↑/↓ 移焦点
(send2 (key-event 'p (mods #t #f #f)))
(send2 (key-event 'up no-mods))
(check-equal? (app-focus b) tv)
(send2 (key-event 'p (mods #t #f #f)))
(send2 (key-event 'down no-mods))
(check-equal? (app-focus b) bv)

;; Ctrl+L：垂直分隔（左右）——继续拆新的 active
(send2 (key-event 'l (mods #t #f #f)))
(check-equal? (length (main-panes)) 3)
(define scr-b (app-render b))                              ; 3 窗格渲染不崩
(check-not-false (string-contains? (screen->string scr-b) "─"))
(check-not-false (string-contains? (screen->string scr-b) "│"))

;; Ctrl+D：关窗格（不关 view）
(send2 (key-event 'd (mods #t #f #f)))
(check-equal? (length (main-panes)) 2)
(send2 (key-event 'd (mods #t #f #f)))
(check-equal? (length (main-panes)) 1)
;; 窗格关了，view 还在（分屏时建的 view 不随窗格消失）
(check-not-false (path-table-did (app-paths b) (build-path root2 "one.txt")))
(check-true (>= (length (editor-document-view-list (b-ed)
                                                  (path-table-did (app-paths b) (build-path root2 "one.txt"))))
                3))

;; 「按焦点删」而不是按顺序/active：拆完焦点在上，删的就是上面那个
(send2 (key-event 'k (mods #t #f #f)))                     ; 再拆成上下两叶
(define pv (tree-vids (app-edit-tree b)))
(check-equal? (length pv) 2)
(send2 (key-event 'p (mods #t #f #f)))
(send2 (key-event 'up no-mods))                            ; 焦点到上面那个
(check-equal? (app-focus b) (car pv))
(check-equal? (app-edit-active b) (car pv))               ; active 已跟随焦点
(send2 (key-event 'd (mods #t #f #f)))                     ; 删焦点窗格（上面）
(check-equal? (length (main-panes)) 1)
(check-equal? (car (main-panes)) (cadr pv))               ; 剩下的是下面那个（不是 active 顺序）
(check-equal? (app-focus b) (cadr pv))                    ; 焦点跟到剩下
;; 重排：剩下的窗格补满主区
(define (pane-rect vid)
  (for/first ([r (in-list (layout-result-panes (app-layout-result b)))]
              #:when (eqv? (rectangle-view-id r) vid)) r))
(check-equal? (rectangle-height (pane-rect (cadr pv))) (app-main-h b))

;; 回归：同一个 view 不能同时占两个编辑窗格（否则删一个会连带删、改一个会连带改）
(send2 (key-event 'k (mods #t #f #f)))                     ; 再拆成两叶
(define w (car (tree-vids (app-edit-tree b))))
(app-show-view! b w)                                       ; 把已在树上的 w 再显示一次
(define vv (tree-vids (app-edit-tree b)))
(check-equal? (length vv) 2)
(check-equal? (length (remove-duplicates vv)) 2)           ; 无重复 vid（会新建一个 view）

;; 任意前缀 & 嵌套前缀：C-x → C-y → ...（外层没被提前清掉）
;; 前缀表里放的是**命令描述**（这里是内置命名命令），不再是裸 lambda。
(define inner-keys (command-table (key 'up) '(focus up)))
(define outer-keys
  (command-table
   (key 'y 'ctrl) (list 'prefix "C-y" (list inner-keys))))
(app-prefix-begin! b "C-x" (list outer-keys))
(check-true (prefix? (app-mode b)))
(send2 (key-event 'y (mods #t #f #f)))                     ; C-x C-y → 进内层前缀
(check-true (prefix? (app-mode b)))
(check-equal? (prefix-label (app-mode b)) "C-y")
(send2 (key-event 'up no-mods))                            ; 内层用完退出
(check-false (app-mode b))

;;; ---------- 插件层：打开带括号的文件 → 按深度背景高亮 ----------

(define root3 (simplify-path (path->complete-path (make-temporary-file "plug~a" 'directory))))
(with-output-to-file (build-path root3 "br.txt") #:exists 'replace (lambda () (display "(a[b])")))
(define c (app-init root3 80 24 #:sidebar-width 24))        ; 默认同步 runner
(define (send3 e) (app-handle-input c e))
(define (c-ed) (app-ed c))
(define (c-tree) (panes-tree (app-panes c)))
(define (c-edit) (app-edit-active c))
(define (c-did) (editor-view-document-id (c-ed) (c-edit)))
(define (hl-at line col) (editor-document-highlight-at (c-ed) (c-did) line col))
;; 一格可能是叠层（face-stack）：取某类的最上层 palette-color。
(define (last-palette v kind)
  (for/last ([l (in-list (face-layers v))]
             #:when (and (palette-color? l) (eq? (palette-color-kind l) kind))) l))
(define (bracket-index v) (palette-color-index (last-palette v 'bracket)))
(define cl (for/first ([e (in-list (tree-entries (app-tree c)))] [i (in-naturals)]
                       #:when (equal? (entry-name e) "br.txt")) i))
(editor-view-set-point! (c-ed) (c-tree) (point cl 0))
(send3 (key-event 'enter no-mods))                          ; 打开（事件末尾 app-plugin-tick!）
(check-equal? (editor-view-string (c-ed) (c-edit)) "(a[b])")
(check-equal? (bracket-index (hl-at 0 0)) 0)           ; (
(check-not-false (last-palette (hl-at 0 1) 'word))     ; a → 词着色（背景仍在）
(check-equal? (bracket-index (hl-at 0 1)) 0)           ; a 的括号背景不被前景覆盖
(check-equal? (bracket-index (hl-at 0 2)) 1)           ; [
(check-equal? (bracket-index (hl-at 0 4)) 1)           ; ]
(check-false (hl-at 0 6))

;; 编辑后自动重算
(set-app-focus! c (c-edit))                                 ; 焦点到编辑格
(send3 (key-event 'end no-mods))
;; 输入插件的自动配对：输 { 直接得到 {}（光标在中间）
(send3 (key-event #\{ no-mods))
(check-equal? (editor-view-string (c-ed) (c-edit)) "(a[b]){}")
(check-equal? (bracket-index (hl-at 0 6)) 0)
(send3 (key-event #\} no-mods))                             ; 跳过已有闭括号，不重复插
(check-equal? (editor-view-string (c-ed) (c-edit)) "(a[b]){}")
(check-equal? (bracket-index (hl-at 0 6)) 0)

;;; ---------- 终端括弧粘贴（paste 事件） ----------

(send3 (key-event 'end no-mods))
(send3 (paste-event #"XY" "XY"))
(check-equal? (editor-view-string (c-ed) (c-edit)) "(a[b]){}XY")
(send3 (paste-event #"1\n2" "1\n2"))                 ; 多行走富粘贴
(check-equal? (editor-view-string (c-ed) (c-edit)) "(a[b]){}XY1\n2")

;; 只读面板（文件树）吞掉粘贴，不改树文档
(define tree-before (editor-view-string (c-ed) (c-tree)))
(set-app-focus! c (c-tree))                            ; 焦点到左栏（树）
(send3 (paste-event #"ZZ" "ZZ"))
(check-equal? (editor-view-string (c-ed) (c-tree)) tree-before)

;;; ---------- 回归：按 document 清理（树删除路径也要清干净）----------

(define br-did (path-table-did (app-paths c) (build-path root3 "br.txt")))
(check-not-false br-did)
(buffers-expand! (app-bufs c) br-did)                      ; 展开它的文档行
(check-true (buffers-expanded? (app-bufs c) br-did))
;; 从文件树删 br.txt → app-close-path! → app-forget-document!
(editor-view-set-point! (c-ed) (c-tree) (point cl 0))
(send3 (key-event 'backspace no-mods))
(send3 (key-event #\y no-mods))
(check-false (file-exists? (build-path root3 "br.txt")))
(check-false (buffers-expanded? (app-bufs c) br-did))      ; 关键：展开状态不残留
(check-false (path-table-did (app-paths c) (build-path root3 "br.txt")))
(check-false (memv br-did (editor-document-id-list (c-ed))))

;;; ---------- 输入插件：自动配对 ----------

(define root4 (simplify-path (path->complete-path (make-temporary-file "pair~a" 'directory))))
(with-output-to-file (build-path root4 "p.rkt") #:exists 'replace (lambda () (display "")))
(define d (app-init root4 80 24 #:sidebar-width 24))
(define (send4 e) (app-handle-input d e))
(define (d-ed) (app-ed d))
(define (d-edit) (app-edit-active d))
(define (d-point) (editor-view-point (d-ed) (d-edit)))
(app-open-path! d (build-path root4 "p.rkt"))
(set-app-focus! d (d-edit))                                ; 焦点到编辑格
(check-true (and (d-edit) #t))

(send4 (key-event #\( no-mods))                            ; ( → 自动补 )
(check-equal? (editor-view-string (d-ed) (d-edit)) "()")
(check-equal? (d-point) (point 0 1))                       ; 光标在中间
(send4 (key-event #\) no-mods))                            ; ) 跳过，不重复
(check-equal? (editor-view-string (d-ed) (d-edit)) "()")
(check-equal? (d-point) (point 0 2))
(send4 (key-event #\[ no-mods))                            ; [ → ]
(check-equal? (editor-view-string (d-ed) (d-edit)) "()[]")
(check-equal? (d-point) (point 0 3))
(send4 (key-event #\> no-mods))                            ; 右邻不是 > → 当普通字符插
(check-equal? (editor-view-string (d-ed) (d-edit)) "()[>]")

;; 有选区时不插手（否则会把选区当普通字符覆盖）
(send4 (key-event 'a (mods #t #f #f)))                     ; 全选
(send4 (key-event #\( no-mods))
(check-equal? (editor-view-string (d-ed) (d-edit)) "(")

;; prompt 里不自动配对
(set-app-focus! d (panes-tree (app-panes d)))             ; 回左栏（树）
(send4 (key-event 'n (mods #t #f #f)))                     ; Ctrl+N 新建文件 prompt
(check-true (prompt? (app-mode d)))
(send4 (key-event #\( no-mods))
(check-equal? (editor-view-string (d-ed) (panes-input (app-panes d))) "new file: (")
(send4 (key-event 'escape no-mods))                        ; 取消 prompt
(check-false (app-mode d))

(displayln "lab smoke-app: ok")
