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
;; 保存
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
