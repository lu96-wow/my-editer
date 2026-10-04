#lang racket

;;; lab-rebuild/smoke-app.rkt —— app 集成冒烟（无终端）：模拟 racket-tui 事件，验证
;;; 文件树打开 / minibuffer 新建 / 焦点移动 / 退出。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "app.rkt"
         "input.rkt"
         "mode.rkt"
         "layout/main.rkt"
         "tree.rkt")

(define root (simplify-path (path->complete-path (make-temporary-file "app~a" 'directory))))
(with-output-to-file (build-path root "aaa.txt") #:exists 'replace (lambda () (display "AAA")))
(with-output-to-file (build-path root "bbb.txt") #:exists 'replace (lambda () (display "BBB")))
(make-directory (build-path root "sub"))
(with-output-to-file (build-path root "sub" "inner.txt") #:exists 'replace (lambda () (display "INNER")))

(define a (app-init root 80 24 #:sidebar-width 24))
(define (send e) (app-handle-input a e))
(define (ed) (app-editor a))
(define (tree-line-of name)
  (for/first ([e (in-list (tree-entries (app-tree a)))] [i (in-naturals)]
              #:when (equal? (entry-name e) name)) i))

;;; ---------- 初始化 / 布局 / 渲染 ----------

(check-equal? (app-focus a) (app-tree-vid a))
(void (app-render a))
(check-true (string-contains? (editor-view-string (ed) (slot-state-vid (app-slot a))) "tree"))
(check-false (app-edit-vid a))                             ; 不预开文档：主区空
(define panes (layout-result-panes (app-layout-result a)))
(check-equal? (map rectangle-view-id panes)
              (list (app-tree-vid a) (slot-state-vid (app-slot a))))
(define scr (app-render a))
(check-equal? (screen-width scr) 80)
(check-equal? (screen-height scr) 24)
;; app-draw! 用的增量渲染路径也不崩
(define-values (scr2 render selection)
  (editor-render-layout-patch (ed) #f panes (app-focus a) 80 24))
(check-true (screen? scr2))
(check-true (list? (append render selection)))

;;; ---------- 树：←/→ 是光标移动；Enter 开关目录 ----------

(define dline (tree-line-of "sub"))
(check-true (exact-nonnegative-integer? dline))
(editor-view-set-point! (ed) (app-tree-vid a) (point dline 0))
(define n0 (length (tree-entries (app-tree a))))
(send (key-event 'enter no-mods))                          ; 展开
(check-true (> (length (tree-entries (app-tree a))) n0))
(send (key-event 'right no-mods))                          ; 光标右移，不折叠
(check-true (> (length (tree-entries (app-tree a))) n0))
(check-true (> (editor-view-point-column (ed) (app-tree-vid a)) 0))
(send (key-event 'left no-mods))
(check-equal? (editor-view-point-column (ed) (app-tree-vid a)) 0)
(send (key-event 'enter no-mods))                          ; 再 Enter 折叠
(check-equal? (length (tree-entries (app-tree a))) n0)

;;; ---------- 树：Enter 打开文件（懒建编辑视图，焦点留在树） ----------

(send (key-event 'right (mods #t #f #f)))                  ; 主区空 → 焦点不动
(check-equal? (app-focus a) (app-tree-vid a))

(define l (tree-line-of "aaa.txt"))
(check-true (exact-nonnegative-integer? l))
(editor-view-set-point! (ed) (app-tree-vid a) (point l 0))
(send (key-event 'enter no-mods))
(check-true (and (app-edit-vid a) #t))
(check-equal? (app-focus a) (app-tree-vid a))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "AAA")

;;; ---------- 焦点移动（Ctrl+右）：主区出现后可用 ----------

(send (key-event 'right (mods #t #f #f)))
(check-equal? (app-focus a) (app-edit-vid a))
(void (app-render a))
(define state-text (editor-view-string (ed) (slot-state-vid (app-slot a))))
(check-true (string-contains? state-text "edit"))         ; 焦点
(check-true (string-contains? state-text "1:1"))          ; 行:列
(check-true (string-contains? state-text "aaa.txt"))      ; view 对应 document 的文件名
(send (key-event 'left (mods #t #f #f)))
(check-equal? (app-focus a) (app-tree-vid a))

;;; ---------- minibuffer：Ctrl+N 新建文件 ----------

(check-equal? (app-focus a) (app-tree-vid a))              ; 打开文件后仍在文件树
(editor-view-set-point! (ed) (app-tree-vid a) (point 0 0)) ; 根
(send (key-event 'n (mods #t #f #f)))                      ; 发起输入
(check-true (and (app-mode a) #t))
(check-equal? (app-focus a) (slot-input-vid (app-slot a)))
(check-equal? (mode-bottom-vid (app-mode a) (app-slot a)) (slot-input-vid (app-slot a)))
(check-equal? (editor-view-string (ed) (slot-input-vid (app-slot a))) "new file: ")
;; 敲名称
(for ([c (in-string "made.txt")]) (send (key-event c no-mods)))
(check-equal? (editor-view-string (ed) (slot-input-vid (app-slot a))) "new file: made.txt")
(send (key-event 'enter no-mods))
(check-false (app-mode a))
(check-equal? (app-focus a) (app-tree-vid a))
(check-true (file-exists? (build-path root "made.txt")))
(check-equal? (mode-bottom-vid (app-mode a) (app-slot a)) (slot-state-vid (app-slot a)))

;;; ---------- minibuffer：Esc 取消 ----------

(send (key-event 'm (mods #t #f #f)))                      ; Ctrl+M 新建目录
(check-true (and (app-mode a) #t))
(send (key-event 'escape no-mods))
(check-false (app-mode a))
(check-false (directory-exists? (build-path root "nomake")))

;;; ---------- 树只读：输入以外不落字符 ----------

(check-equal? (app-focus a) (app-tree-vid a))              ; 取消后焦点已回文件树
(editor-view-set-point! (ed) (app-tree-vid a) (point 0 1000))
(define before (editor-view-string (ed) (app-tree-vid a)))
(send (key-event #\Z no-mods))                             ; 无修饰字符 = text
(check-equal? (editor-view-string (ed) (app-tree-vid a)) before)

;;; ---------- 确认型 prompt 复用同一个 input 文档 ----------

(define dl (tree-line-of "aaa.txt"))
(check-true (exact-nonnegative-integer? dl))
(editor-view-set-point! (ed) (app-tree-vid a) (point dl 0))
(send (key-event 'backspace no-mods))                      ; 删除确认（y/n）
(check-true (and (app-mode a) (not (prompt-editable? (app-mode a)))))
(check-equal? (app-focus a) (slot-input-vid (app-slot a)))
(check-equal? (mode-bottom-vid (app-mode a) (app-slot a)) (slot-input-vid (app-slot a)))
(check-true (string-contains? (editor-view-string (ed) (slot-input-vid (app-slot a))) "delete"))
(send (key-event #\n no-mods))                              ; n = 不删
(check-false (app-mode a))
(check-true (file-exists? (build-path root "aaa.txt")))
(check-equal? (app-focus a) (app-tree-vid a))

;;; ---------- 左侧 Tab 切换 + 文档 / 视图列表 ----------

(check-equal? (app-focus a) (app-tree-vid a))              ; 仍在文件树
(send (key-event 'o (mods #t #f #f)))                     ; 焦点切到编辑格
(check-equal? (app-focus a) (app-edit-vid a))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "AAA")
(send (key-event 'o (mods #t #f #f)))                     ; 再切回左栏
(check-equal? (app-focus a) (app-tree-vid a))
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'bufs)
(check-equal? (app-focus a) (app-bufs-vid a))
(check-equal? (rectangle-view-id (car (layout-result-panes (app-layout-result a))))
              (app-bufs-vid a))
(define bufs-text (editor-view-string (ed) (app-bufs-vid a)))
(check-false (string-contains? bufs-text "*scratch*"))
(check-true (string-contains? bufs-text "aaa.txt"))

;; 展开 aaa.txt 的 doc 行 → 出现 view 行；选 view 行 Enter 打开到编辑格
(define (buf-line pred)
  (for/first ([s (in-list (string-split (editor-view-string (ed) (app-bufs-vid a)) "\n"))]
              [i (in-naturals)] #:when (pred s)) i))
(editor-view-set-point! (ed) (app-bufs-vid a) (point (buf-line (lambda (s) (equal? s "aaa.txt"))) 0))
(send (key-event 'enter no-mods))
(check-true (string-contains? (editor-view-string (ed) (app-bufs-vid a)) "view"))
(editor-view-set-point! (ed) (app-bufs-vid a)
                        (point (buf-line (lambda (s) (string-contains? s "view"))) 0))
(send (key-event 'enter no-mods))
(check-equal? (app-focus a) (app-edit-vid a))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "AAA")

;; 再 Tab 回文件树
(send (key-event 'o (mods #t #f #f)))                     ; 焦点回左栏
(check-equal? (app-focus a) (app-bufs-vid a))
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'tree)
(check-equal? (app-focus a) (app-tree-vid a))

;;; ---------- 鼠标：输入时点别处取消；点输入行定位 ----------

(editor-view-set-point! (ed) (app-tree-vid a) (point 0 0))
(send (key-event 'n (mods #t #f #f)))                     ; 打开输入
(check-true (and (app-mode a) #t))
(send (mouse-event 'press 'left 31 11 no-mods))           ; 点在编辑区（1-based）→ 取消
(check-false (app-mode a))

(send (key-event 'n (mods #t #f #f)))                     ; 再开
(define invid (slot-input-vid (app-slot a)))
(send (mouse-event 'press 'left 31 24 no-mods))           ; 点输入行自身（1-based）
(check-true (and (app-mode a) #t))                        ; 不取消
(check-equal? (app-focus a) invid)
;; 1-based (31,24) → 0-based 屏幕格 (30,23) → 输入视图内列 30-24 = 6
(check-equal? (editor-view-point-column (ed) invid) 6)
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;; 正常模式：点编辑区聚焦
(send (mouse-event 'press 'left 41 6 no-mods))
(check-equal? (app-focus a) (app-edit-vid a))

;;; ---------- 删除已打开的文件：同步关闭文档 / 视图 ----------

(send (key-event 'o (mods #t #f #f)))                     ; 回左栏
(check-equal? (app-focus a) (app-tree-vid a))
(editor-view-set-point! (ed) (app-tree-vid a) (point 0 0)) ; 根
(send (key-event 'n (mods #t #f #f)))                     ; Ctrl+N 新建 gone.txt
(for ([c (in-string "gone.txt")]) (send (key-event c no-mods)))
(send (key-event 'enter no-mods))
(check-true (file-exists? (build-path root "gone.txt")))
(editor-view-set-point! (ed) (app-tree-vid a) (point (tree-line-of "gone.txt") 0))
(send (key-event 'enter no-mods))                          ; 打开（焦点仍在树）
(check-equal? (app-focus a) (app-tree-vid a))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "")
(send (key-event 'backspace no-mods))                      ; 删除确认
(check-true (and (app-mode a) (not (prompt-editable? (app-mode a)))))
(send (key-event #\y no-mods))
(check-false (app-mode a))
(check-false (file-exists? (build-path root "gone.txt")))
(check-false (hash-has-key? (app-by-path a) (simplify-path (build-path root "gone.txt"))))
;; 编辑格改显下一个还开着的 aaa.txt，文档列表里 gone.txt 也没了
(check-true (and (app-edit-vid a) #t))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "AAA")
(check-false (string-contains? (editor-view-string (ed) (app-bufs-vid a)) "gone.txt"))

;;; ---------- 删除目录：连带关闭目录下已打开的文档 ----------

(define subpath (simplify-path (build-path root "sub")))
(unless (tree-expanded? (app-tree a) subpath)
  (editor-view-set-point! (ed) (app-tree-vid a) (point (tree-line-of "sub") 0))
  (send (key-event 'enter no-mods)))                       ; 展开 sub
(editor-view-set-point! (ed) (app-tree-vid a) (point (tree-line-of "inner.txt") 0))
(send (key-event 'enter no-mods))                          ; 打开 sub/inner.txt
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "INNER")
(editor-view-set-point! (ed) (app-tree-vid a) (point (tree-line-of "sub") 0))
(send (key-event 'backspace no-mods))                      ; 删目录
(send (key-event #\y no-mods))
(check-false (directory-exists? (build-path root "sub")))
(check-false (hash-has-key? (app-by-path a) (simplify-path (build-path root "sub" "inner.txt"))))
(check-false (string-contains? (editor-view-string (ed) (app-bufs-vid a)) "inner.txt"))
(check-equal? (editor-view-string (ed) (app-edit-vid a)) "AAA")  ; 回落到 aaa.txt

;;; ---------- 退出 ----------

(send (key-event 'q (mods #t #f #f)))
(check-true (app-quit? a))

(displayln "lab-rebuild smoke-app: ok")
