#lang racket

;;; lab/smoke-app.rkt —— app 集成冒烟（无终端）：模拟 racket-tui 事件，验证
;;; 文件树打开 / minibuffer 新建 / 输入转移 / 焦点 / 增删同步。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "base/input.rkt"
         "base/layout/main.rkt"
         "ui/tree.rkt"
         "ui/mode.rkt"
         "app/app.rkt"
         "app/state.rkt"
         "app/panes.rkt"
         "app/paths.rkt")

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
(define (edit-vid) (panes-edit (app-panes a)))
(define (state-vid) (panes-state (app-panes a)))
(define (input-vid) (panes-input (app-panes a)))
(define (tree-line-of name)
  (for/first ([e (in-list (tree-entries (app-tree a)))] [i (in-naturals)]
              #:when (equal? (entry-name e) name)) i))

;;; ---------- 初始化 / 布局 / 渲染 ----------

(check-equal? (app-focus a) (tree-vid))
(void (app-prepare! a))
(check-true (string-contains? (editor-view-string (ed) (state-vid)) "tree"))
(check-false (edit-vid))                                   ; 不预开文档：主区空
(define panes (layout-result-panes (app-layout-result a)))
(check-equal? (map rectangle-view-id panes) (list (tree-vid) (state-vid)))
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

(send (key-event 'right (mods #t #f #f)))                  ; 主区空 → 焦点不动
(check-equal? (app-focus a) (tree-vid))

(define l (tree-line-of "aaa.txt"))
(check-true (exact-nonnegative-integer? l))
(editor-view-set-point! (ed) (tree-vid) (point l 0))
(send (key-event 'enter no-mods))
(check-true (and (edit-vid) #t))
(check-equal? (app-focus a) (tree-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")

;;; ---------- 焦点移动（Ctrl+右）：主区出现后可用；state 行三段 ----------

(send (key-event 'right (mods #t #f #f)))
(check-equal? (app-focus a) (edit-vid))
(void (app-prepare! a))
(define state-text (editor-view-string (ed) (state-vid)))
(check-true (string-contains? state-text "edit"))         ; 焦点
(check-true (string-contains? state-text "1:1"))          ; 行:列
(check-true (string-contains? state-text "aaa.txt"))      ; view 对应 document 的文件名
(send (key-event 'left (mods #t #f #f)))
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
(check-true (string-contains? (editor-view-string (ed) (input-vid)) "delete"))
(send (key-event #\n no-mods))                             ; n = 不删
(check-false (app-mode a))
(check-true (file-exists? (build-path root "aaa.txt")))
(check-equal? (app-focus a) (tree-vid))

;;; ---------- 左侧 Tab 切换 + 文档 / 视图列表 ----------

(check-equal? (app-focus a) (tree-vid))
(send (key-event 'o (mods #t #f #f)))                     ; 焦点切到编辑格
(check-equal? (app-focus a) (edit-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")
(send (key-event 'o (mods #t #f #f)))                     ; 再切回左栏
(check-equal? (app-focus a) (tree-vid))
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'bufs)
(check-equal? (app-focus a) (bufs-vid))
(check-equal? (rectangle-view-id (car (layout-result-panes (app-layout-result a))))
              (bufs-vid))
(define bufs-text (editor-view-string (ed) (bufs-vid)))
(check-false (string-contains? bufs-text "*scratch*"))
(check-false (string-contains? bufs-text "*state*"))
(check-true (string-contains? bufs-text "aaa.txt"))

;; 展开 aaa.txt 的 doc 行 → 出现 view 行；选 view 行 Enter 打开到编辑格
(define (buf-line pred)
  (for/first ([s (in-list (string-split (editor-view-string (ed) (bufs-vid)) "\n"))]
              [i (in-naturals)] #:when (pred s)) i))
(editor-view-set-point! (ed) (bufs-vid) (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
(send (key-event 'enter no-mods))
(check-true (string-contains? (editor-view-string (ed) (bufs-vid)) "view"))
(editor-view-set-point! (ed) (bufs-vid)
                        (point (buf-line (lambda (s) (string-contains? s "view"))) 0))
(send (key-event 'enter no-mods))
(check-equal? (app-focus a) (edit-vid))
(check-equal? (editor-view-string (ed) (edit-vid)) "AAA")

;; 再切回文件树
(send (key-event 'o (mods #t #f #f)))                     ; 焦点回左栏
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

(send (key-event 'o (mods #t #f #f)))                     ; 回左栏
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

;;; ---------- 退出 ----------

(send (key-event 'q (mods #t #f #f)))
(check-true (app-quit? a))

(displayln "lab smoke-app: ok")
