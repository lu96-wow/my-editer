#lang racket

;;; lab-rebuild/smoke-platform.rkt —— L1 平台骨架冒烟
;;;
;;; 验证：input / keymap / dispatch / layout / mode / edit-panes / state 装得上、跑得通，
;;; 并且一个最小 app 能开文件、编辑、渲染、保存。

(require rackunit
         racket/file
         racket/path
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "platform/input.rkt"
         "platform/keymap.rkt"
         "platform/dispatch.rkt"
         "platform/layout/main.rkt"
         "platform/slot.rkt"
         "platform/mode.rkt"
         "platform/hooks.rkt"
         "platform/overlay.rkt"
         "platform/edit-panes.rkt"
         "platform/state.rkt"
         "platform/panes.rkt"
         "platform/paths.rkt"
         "app/app.rkt"
         "builtin/edit.rkt"
         "config/keys.rkt")

;;; ---------- input ----------

(check-equal? (normalize-mods '(shift ctrl bogus)) '(ctrl shift))
(check-equal? (event->binding (key-event #\X (mods #t #f #f))) (key 'x 'ctrl))
(check-equal? (event->binding (key-event 'up no-mods)) (key 'up))
(check-equal? (event->binding (key-event #\a no-mods)) text-binding)
(check-equal? (event->binding (paste-event #"hi" "hi")) paste-binding)
(check-false (event->binding (null-event)))

;;; ---------- keymap / dispatch ----------

(define global (command-table (key 'tab) 'g-tab (key 'enter) 'g-enter))
(define doc-t  (command-table (key 'enter) 'd-enter))
(define extra  (command-table (key 'enter) 'm-enter))
(define cs (command-set-add-doc (command-set (list global)) 7 doc-t))

(check-equal? (dispatch-tables cs 7 (list extra)) (list global doc-t extra))
(check-equal? (dispatch-lookup cs 7 '() (key-event 'enter no-mods)) 'd-enter)
(check-equal? (dispatch-lookup cs 7 '() (key-event 'tab no-mods)) 'g-tab)
(check-equal? (dispatch-lookup cs 7 (list extra) (key-event 'enter no-mods)) 'm-enter)
(check-false (dispatch-lookup cs 9 '() (key-event 'backspace no-mods)))

;;; ---------- keymap：命名 registry + 运行时增删 + 合并优先级 ----------

(check-not-false (keymap-ref 'edit))
;; 运行时往命名 keymap 补键：command-set 持有同一对象，立即生效
(define cs2 (command-set (list (keymap-ref 'global))))
(keymap-add! (keymap-ref 'global) (key 'f10) 'noop)
(check-equal? (command-set-lookup cs2 #f (key 'f10)) 'noop)
(keymap-remove! (keymap-ref 'global) (key 'f10))
(check-false (command-set-lookup cs2 #f (key 'f10)))
;; 匿名表可增删
(define km (command-table (key 'a) 'x))
(keymap-add! km (key 'b) 'y)
(check-equal? (command-lookup (list km) (key 'b)) 'y)
(keymap-remove! km (key 'a))
(check-false (command-lookup (list km) (key 'a)))
;; merge：后面覆盖前面
(check-equal? (command-lookup (list (command-table (key 'enter) 'a)
                                    (command-table (key 'enter) 'b))
                              (key 'enter))
              'b)

;;; ---------- layout ----------

(define main (regions-main (compute-regions 80 24)))
(define-values (ps bs _ws) (tree->rectangles (node 'lr #f (leaf 0) (leaf 1)) main))
(check-equal? (map rectangle-view-id ps) '(0 1))
(check-equal? (list (bar-x (car bs)) (bar-width (car bs))) '(51 1))
(define lr (compute-layout (node 'lr #f (leaf 0) (leaf 1)) 80 24
                           #:sidebar? #f #:bottom-vid 11))
(check-equal? (map rectangle-view-id (layout-result-panes lr)) '(0 1 11))
(check-equal? (layout-right lr 0) 1)

;;; ---------- mode（prompt / prefix） ----------

(define ed0 (editor-open "main" 56 23 "main"))
(define-values (ed1 _sd stvid) (editor-add-document-view ed0 (state->document "1:1") 56 1 "*state*"))
(define-values (ed2 _id invid) (editor-add-document-view ed1 (input->document (input "name: " #t)) 56 1 "*input*"))
(define got (box 'none))
(define p (input-begin "name: " #t 0 (lambda (v) (set-box! got v))))
(check-equal? (mode-bottom-vid p stvid invid) invid)
(check-equal? (mode-focus-vid p invid) invid)
(editor-view-assign! ed2 invid (prompt-document p ""))
(editor-view-set-point! ed2 invid (point 0 (string-length "name: ")))
(define-values (_changes _ok) (editor-view-insert! ed2 invid "x.txt"))
(void (input-commit p (editor-view-string ed2 invid)))
(check-equal? (unbox got) "x.txt")
(check-false (mode-focus-vid #f invid))
(define pf (prefix-begin "C-p" (list (command-table (key 'up) 'x))))
(check-equal? (mode-bottom-vid pf stvid invid) stvid)
(check-equal? (length (mode-tables pf)) 1)

;;; ---------- mode 注册表：第三方 mode-type ----------

(struct fake-mode (tag) #:transparent)
(define fake-keys (command-table (key 'f1) 'noop))
(void (mode-type-register!
       (mode-type 'fake fake-mode?
                  (lambda (_) (list fake-keys))
                  (lambda (_) 'input)
                  (lambda (_) 'input)
                  #f #f)))
(check-equal? (mode-bottom-vid (fake-mode 1) stvid invid) invid)
(check-equal? (mode-focus-vid (fake-mode 1) invid) invid)
(check-equal? (mode-tables (fake-mode 1)) (list fake-keys))
(check-not-false (mode-active-type (fake-mode 1)))
(check-false (mode-exclusive? (fake-mode 1)))
;; 空闲 / 前缀
(check-equal? (mode-bottom-vid #f stvid invid) stvid)
(check-true (mode-exclusive? (prefix-begin "x" '())))
(check-true (mode-transient? (prefix-begin "x" '())))
(mode-type-unregister! 'fake)
(check-false (mode-active-type (fake-mode 1)))

;;; ---------- edit-panes ----------

(define ep (edit-panes-empty))
(void (edit-panes-open! ep 5))
(check-equal? (edit-panes-tree ep) (leaf 5))
(void (edit-panes-open! ep 6))
(check-equal? (edit-panes-tree ep) (leaf 6))

;;; ---------- 最小 app：开文件 / 编辑 / 保存 / 渲染 ----------

(define root (simplify-path (path->complete-path (make-temporary-file "pl~a" 'directory))))
(define f (build-path root "a.rkt"))
(with-output-to-file f #:exists 'replace (lambda () (display "#lang racket\n")))

(define a (app-init root 80 24))
(define (send e) (app-handle-input a e))
(app-open-path! a f)
(check-true (edit-panes-contains? (app-edit a) (app-focus a)))
(define vid (app-focus a))

;; 打字进入文档
(for ([c (string->list "(define x 1)")]) (send (key-event c no-mods)))
(check-true (string-contains? (editor-view-string (app-ed a) vid) "(define x 1)"))
;; 状态栏 = 主区宽
(void (app-render a))
(define svid (panes-state (app-panes a)))
(check-equal? (string-length (editor-view-string (app-ed a) svid)) (app-main-w a))
;; 渲染不崩
(check-not-false (screen? (app-render a)))
;; 保存（C-s）
(send (key-event 's (mods #t #f #f)))
(check-true (string-contains? (file->string f) "(define x 1)"))
;; 分屏 + 关窗格
(send (key-event 'l (mods #t #f #f)))
(check-equal? (length (edit-panes-vids (app-edit a))) 2)
(send (key-event 'd (mods #t #f #f)))
(check-equal? (length (edit-panes-vids (app-edit a))) 1)
;; 前缀键：C-p 后 escape 退出，不崩
(send (key-event 'p (mods #t #f #f)))
(check-true (prefix? (app-mode a)))
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;;; ---------- 编辑窗格：移动 / 调整大小 ----------

;; 纯树：交换两个 leaf 的 vid（位置不变，只换内容）
(check-equal? (tree-swap (node 'lr 5 (leaf 1) (leaf 2)) 1 2)
              (node 'lr 5 (leaf 2) (leaf 1)))
(check-equal? (tree-swap (node 'lr 5 (leaf 1) (node 'tb #f (leaf 2) (leaf 3))) 1 3)
              (node 'lr 5 (leaf 3) (node 'tb #f (leaf 2) (leaf 1))))

;; edit-panes：swap / resize
(define ep2 (edit-panes-empty))
(void (edit-panes-open! ep2 1))
(void (edit-panes-split! ep2 'lr 2))
(edit-panes-swap! ep2 1 2)
(check-equal? (edit-panes-tree ep2) (node 'lr #f (leaf 2) (leaf 1)))
(edit-panes-resize! ep2 2 'width 1 (area 0 0 40 10))
(check-equal? (node-size (edit-panes-tree ep2)) 20)

;; 上下：下格 active 时 down 放大 → 上段高度 4→3，up 缩小 → 3→4
(define ep3 (edit-panes-empty))
(void (edit-panes-open! ep3 1))
(void (edit-panes-split! ep3 'tb 2))
(check-false (node-size (edit-panes-tree ep3)))
(edit-panes-resize! ep3 2 'height 1 (area 0 0 40 10))
(check-equal? (node-size (edit-panes-tree ep3)) 3)
(edit-panes-resize! ep3 2 'height -1 (area 0 0 40 10))
(check-equal? (node-size (edit-panes-tree ep3)) 4)

;; app：拆左右两格 → M-m + left 交换；M-s + right 变大
(define root3 (simplify-path (path->complete-path (make-temporary-file "pl~a" 'directory))))
(define f3 (build-path root3 "panes.rkt"))
(with-output-to-file f3 #:exists 'replace (lambda () (display "")))
(define a3 (app-init root3 80 24))
(define (send3 e) (app-handle-input a3 e))
(app-open-path! a3 f3)
(send3 (key-event 'l (mods #t #f #f)))            ; C-l 左右拆
(check-equal? (length (edit-panes-vids (app-edit a3))) 2)
(define rvid (app-edit-active a3))
(define lvid (for/first ([v (in-list (edit-panes-vids (app-edit a3)))] #:unless (eqv? v rvid)) v))
;; M-m 前缀 + left → 与左格交换
(send3 (key-event #\m (mods #f #t #f)))
(check-true (prefix? (app-mode a3)))
(send3 (key-event 'left no-mods))
(check-false (app-mode a3))
(check-equal? (leaf-vid (node-a (edit-panes-tree (app-edit a3)))) rvid)
(check-equal? (leaf-vid (node-b (edit-panes-tree (app-edit a3)))) lvid)
;; active（rvid）现在在 a；M-s + right → size +1（第一次落定具体值，第二次 +1）
(send3 (key-event #\s (mods #f #t #f)))
(check-true (prefix? (app-mode a3)))
(send3 (key-event 'right no-mods))
(check-false (app-mode a3))
(define s1 (node-size (edit-panes-tree (app-edit a3))))
(check-true (positive? s1))
(send3 (key-event #\s (mods #f #t #f)))
(send3 (key-event 'right no-mods))
(check-equal? (node-size (edit-panes-tree (app-edit a3))) (add1 s1))

;; 路径（a）：任意两个编辑窗格直接互换
(app-swap-panes! a3 rvid lvid)
(check-equal? (leaf-vid (node-a (edit-panes-tree (app-edit a3)))) lvid)
(check-equal? (leaf-vid (node-b (edit-panes-tree (app-edit a3)))) rvid)
(app-swap-panes! a3 rvid lvid)                    ; 换回：rvid 在 a
(check-equal? (leaf-vid (node-a (edit-panes-tree (app-edit a3)))) rvid)

;; 路径（b）：M-m 前缀 + 点击右格 → 互换
(define target-rect
  (for/first ([r (in-list (layout-result-panes (app-layout-result a3)))]
              #:when (eqv? (rectangle-view-id r) lvid))
    r))
(define tx (+ (rectangle-x target-rect) (quotient (rectangle-width target-rect) 2)))
(define ty (+ (rectangle-y target-rect) (quotient (rectangle-height target-rect) 2)))
(send3 (key-event #\m (mods #f #t #f)))            ; M-m 前缀
(check-true (prefix? (app-mode a3)))
(send3 (mouse-event 'press #f (add1 tx) (add1 ty) no-mods))   ; 1-based 点击
(check-false (app-mode a3))
(check-equal? (leaf-vid (node-a (edit-panes-tree (app-edit a3)))) lvid)
(check-equal? (leaf-vid (node-b (edit-panes-tree (app-edit a3)))) rvid)

;; 只限编辑区：点击左栏不换
(define left-rect
  (for/first ([r (in-list (layout-result-panes (app-layout-result a3)))]
              #:when (eqv? (rectangle-view-id r) (app-left-vid a3)))
    r))
(when left-rect
  (define lx (+ (rectangle-x left-rect) (quotient (rectangle-width left-rect) 2)))
  (define ly (+ (rectangle-y left-rect) (quotient (rectangle-height left-rect) 2)))
  (send3 (key-event #\m (mods #f #t #f)))
  (send3 (mouse-event 'press #f (add1 lx) (add1 ly) no-mods))
  (check-equal? (leaf-vid (node-a (edit-panes-tree (app-edit a3)))) lvid)
  (check-equal? (leaf-vid (node-b (edit-panes-tree (app-edit a3)))) rvid))

;;; ---------- prompt：走 mode 注册表 + dispatch 回落 ----------

(define got2 (box #f))
(app-begin! a "name: " #t (lambda (v) (set-box! got2 v)))
(check-true (prompt? (app-mode a)))
(define invid2 (app-modal-vid a))
(check-equal? (app-focus a) invid2)
(check-equal? (app-bottom-vid a) invid2)
;; 普通字符落回 edit-keys → 插进输入文档
(for ([c (string->list "hi")]) (send (key-event c no-mods)))
(check-true (string-contains? (editor-view-string (app-ed a) invid2) "hi"))
;; Enter（input-edit keymap）提交，值剥掉 label 回传
(send (key-event 'enter no-mods))
(check-false (app-mode a))
(check-equal? (unbox got2) "hi")

;;; ---------- 钩子：before-insert / after-edit / post-command ----------

(define seen-text (box #f))
(hook-add! a 'before-insert (lambda (a text) (set-box! seen-text text) #f))
(send (key-event #\z no-mods))
(check-equal? (unbox seen-text) "z")

;; 拦截：吞掉 "?"
(hook-add! a 'before-insert (lambda (a text) (and (equal? text "?") '())))
(define before-len (string-length (editor-view-string (app-ed a) vid)))
(send (key-event #\? no-mods))
(check-equal? (string-length (editor-view-string (app-ed a) vid)) before-len)

;; after-edit 广播
(define edited? (box #f))
(hook-add! a 'after-edit (lambda (a vid changes) (set-box! edited? #t)))
(send (key-event #\w no-mods))
(check-true (unbox edited?))

;; post-command 每个事件后都会跑
(define pc (box 0))
(hook-add! a 'post-command (lambda (a) (set-box! pc (add1 (unbox pc)))))
(send (key-event #\v no-mods))
(check-true (> (unbox pc) 0))

;;; ---------- overlay provider 注册表 ----------

(define (fake-overlay a) (list 'fake-overlay))
(void (overlay-register! fake-overlay))
(check-equal? (overlay-panes a) '(fake-overlay))
(overlay-unregister! fake-overlay)
(check-equal? (overlay-panes a) '())

;;; ---------- 关闭 / 退出：修改过先问保存 ----------

(define root2 (simplify-path (path->complete-path (make-temporary-file "pl~a" 'directory))))
(define d1 (build-path root2 "one.rkt"))
(define d2 (build-path root2 "two.rkt"))
(with-output-to-file d1 #:exists 'replace (lambda () (display "one")))
(with-output-to-file d2 #:exists 'replace (lambda () (display "two")))

(define a2 (app-init root2 80 24))
(define (send2 e) (app-handle-input a2 e))

;; 未改过的文档不算脏，直接关、不弹提示
(app-open-path! a2 d1)
(define did1 (focused-did a2))
(check-false (document-modified? a2 did1))
(app-close-document! a2 did1)
(check-false (prompt? (app-mode a2)))
(check-false (path-table-open? (app-paths a2) d1))

;; 改一下 → 脏；关文档先弹提示，还没真关
(app-open-path! a2 d1)
(define did1b (focused-did a2))
(send2 (key-event #\x no-mods))                    ; d1 = "xone"
(check-true (document-modified? a2 did1b))
(app-close-document! a2 did1b)
(check-true (prompt? (app-mode a2)))
(check-true (path-table-open? (app-paths a2) d1))
;; 输入 n + ⏎ → 不保存，关闭
(send2 (key-event #\n no-mods))
(send2 (key-event 'enter no-mods))
(check-false (app-mode a2))
(check-false (path-table-open? (app-paths a2) d1))
(check-equal? (file->string d1) "one")

;; esc 放弃退出：不保存、不关、不退出
(app-open-path! a2 d1)
(define did1c (focused-did a2))
(send2 (key-event #\y no-mods))                    ; d1 = "yone"
(app-quit! a2)
(check-true (prompt? (app-mode a2)))
(send2 (key-event 'escape no-mods))
(check-false (app-quit? a2))
(check-true (path-table-open? (app-paths a2) d1))
(check-equal? (file->string d1) "one")

;; all：两个脏文档全部保存后再退出
(app-open-path! a2 d2)
(define did2 (focused-did a2))
(send2 (key-event #\b no-mods))                    ; d2 = "btwo"
(app-quit! a2)
(check-true (prompt? (app-mode a2)))
(for ([c (string->list "all")]) (send2 (key-event c no-mods)))
(send2 (key-event 'enter no-mods))
(check-true (app-quit? a2))
(check-false (path-table-open? (app-paths a2) d1))
(check-false (path-table-open? (app-paths a2) d2))
(check-equal? (file->string d1) "yone")
(check-equal? (file->string d2) "btwo")

(void (app-render a))
(displayln "platform smoke: ok")
