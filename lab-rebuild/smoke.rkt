#lang racket

;;; lab-rebuild/smoke.rkt —— 无头冒烟：编辑 / 焦点 / 命令 / 主区+dock / 文件与输入。
;;; 注意：ctx 共享同一个可变 editor，必须用**返回的 ctx** 顺序往下走。

(require rackunit
         racket/file
         racket/path
         "app/app.rkt"
         "kernel/api.rkt"
         "builtin/document-api.rkt"
         "builtin/document.rkt"
         "builtin/doc-scope.rkt"
         "builtin/indent.rkt"
         "builtin/tree.rkt"
         "builtin/highlight/bracket-pair.rkt"
         "builtin/translate.rkt"
         "config/theme.rkt")

(define (press ctx ch) (step ctx (key-event ch no-mods)))
(define (press-ctrl ctx ch) (step ctx (key-event ch (mods #t #f #f))))
(define (press-alt ctx ch) (step ctx (key-event ch (mods #f #t #f))))
(define (type-all ctx s) (for/fold ([c ctx]) ([ch (in-string s)]) (press c ch)))
(define (effects! ctx effs) (for/fold ([c ctx]) ([e (in-list effs)]) (apply-effect c e)))
(define (render! ctx) (app-render ctx) (void))
(define (view-string ctx)
  (editor-view-string (session-editor (ctx-session ctx)) (session-focus-vid (ctx-session ctx))))
(define (doc-string ctx did)
  (editor-document-string (session-editor (ctx-session ctx)) did))
(define (dock-string ctx id)
  (define vid (workspace-dock-vid (session-workspace (ctx-session ctx)) id))
  (and vid (editor-view-string (session-editor (ctx-session ctx)) vid)))
;; 往运行时注册表注入一条贡献，得到新 ctx（用于测扩展点，如 doc-scope）。
(define (add-contrib c kind name value)
  (define rt (ctx-runtime c))
  (ctx (ctx-session c)
       (make-runtime (reg-add (runtime-registry rt) (contrib kind name value))
                     (runtime-services rt))))
;; 覆盖 doc-scope 的 'complete 为恒 #f，隔离补全自动弹出（layer/mouse 纯机制测试用）。
(define (no-complete c)
  (add-contrib c 'doc-scope 'complete (doc-scope (lambda (_p _g) #f))))

;; 临时根目录：sub/inner.txt + hello.txt
(define root (make-temporary-file "lab-rebuild-~a" 'directory))
(make-directory (build-path root "sub"))
(call-with-output-file (build-path root "sub" "inner.txt") #:exists 'truncate (λ (o) (display "inner" o)))
(call-with-output-file (build-path root "hello.txt") #:exists 'truncate (λ (o) (display "hi" o)))

(define ctx0 (app-init root 60 14))
(define main0 (session-edit-vid (ctx-session ctx0)))
(check-true (number? main0) "初始活动编辑视图")

;; --- 编辑 + 脏标记 ---
(define ctx1 (press (press ctx0 #\h) #\i))
(check-equal? (view-string ctx1) "hi" "打字")
(render! ctx1)
(check-true (regexp-match? #rx"\\*" (dock-string ctx1 'status)) "编辑后状态栏有脏标记 *")

;; --- 主区分屏 + 粘性 edit-vid ---
(define ctx2 (press-ctrl ctx1 #\l))
(check-equal? (length (frame-leaves (workspace-main (session-workspace (ctx-session ctx2))))) 2 "C-l 分屏")
(check-equal? (session-edit-vid (ctx-session ctx2)) (session-focus-vid (ctx-session ctx2)) "分屏后 edit-vid=新焦点")
(define ctx3 (press-alt ctx2 #\h))
(check-equal? (session-focus-vid (ctx-session ctx3)) main0 "M-h 焦点回左叶")
(check-equal? (session-edit-vid (ctx-session ctx3)) main0 "edit-vid 跟随")

;; --- tree dock：显示 / 内容 / 展开 ---
(define ctx4 (press-ctrl ctx3 #\b))
(define tree-vid (workspace-dock-vid (session-workspace (ctx-session ctx4)) 'tree))
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctx4)) 'tree)) "C-b 显示 tree")
(check-equal? (session-focus-vid (ctx-session ctx4)) tree-vid "焦点进 tree")
(check-equal? (session-edit-vid (ctx-session ctx4)) main0 "进 dock 不改 edit-vid")
(render! ctx4)
(check-true (regexp-match? #rx"hello\\.txt" (dock-string ctx4 'tree)) "tree 列文件")
(check-true (regexp-match? #rx"sub/" (dock-string ctx4 'tree)) "tree 列目录")

;; 展开 sub/：root(0) sub/(1) inner(2) hello(3)
(define ctx5 (effects! ctx4 (list (e-move tree-vid (selections-one (caret (point 1 0)))))))
(define ctx6 (step ctx5 (key-event 'enter no-mods)))
(render! ctx6)
(check-true (regexp-match? #rx"inner\\.txt" (dock-string ctx6 'tree)) "Enter 展开目录")

;; --- 打开文件（tree Enter）→ 主区 + 状态栏 ---
(define ctx7 (effects! ctx6 (list (e-move tree-vid (selections-one (caret (point 3 0))))))) ; hello.txt
(define ctx8 (step ctx7 (key-event 'enter no-mods)))
(check-equal? (view-string ctx8) "hi" "打开 hello.txt")
(render! ctx8)
(check-true (regexp-match? #rx"hello\\.txt" (dock-string ctx8 'status)) "状态栏显示文件名")

;; --- doc-scope：能力对当前文档是否启用 ---
(check-equal? (current-doc-path ctx8) (simplify-path (build-path root "hello.txt")) "doc-scope: 当前路径")
(check-equal? (current-doc-text ctx8) "hi" "doc-scope: 当前全文")
(check-true (doc-applies? ctx8 'unregistered) "doc-scope: 无声明默认启用")
(define ctx-scope
  (add-contrib ctx8 'doc-scope 'txt-only
               (doc-scope (lambda (p _get) (and p (regexp-match? #rx"[.]txt$" (path->string p)))))))
(define ctx-scope-rkt
  (add-contrib ctx8 'doc-scope 'rkt-only
               (doc-scope (lambda (p _get) (and p (regexp-match? #rx"[.]rkt$" (path->string p)))))))
(check-true (doc-applies? ctx-scope 'txt-only) "doc-scope: .txt 能力对 hello.txt 启用")
(check-false (doc-applies? ctx-scope-rkt 'rkt-only) "doc-scope: .rkt 能力对 hello.txt 不启用")

;; --- 编辑并保存 ---
(define ctx9 (effects! ctx8 (list (e-nav (session-edit-vid (ctx-session ctx8)) 'end #f))))
(define ctx9b (press ctx9 #\X))
(check-equal? (view-string ctx9b) "hiX" "编辑打开的文件")
(render! ctx9b)
(check-true (regexp-match? #rx"hello\\.txt \\*" (dock-string ctx9b 'status)) "未存显示 *")
(define ctx10 (press-ctrl ctx9b #\s))
(check-equal? (file->string (build-path root "hello.txt")) "hiX" "C-s 写盘")
(render! ctx10)
(check-false (regexp-match? #rx"\\*" (dock-string ctx10 'status)) "保存后不脏")

;; --- 输入 dock：新建文件 ---
(define ctx11 (effects! ctx10 (list (e-focus tree-vid)
                                    (e-move tree-vid (selections-one (caret (point 0 0))))))) ; 光标到 root
(define ctx12 (step ctx11 (key-event #\n (mods #t #f #f))))     ; C-n
(define input-vid (workspace-dock-vid (session-workspace (ctx-session ctx12)) 'input))
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctx12)) 'input)) "prompt 显示 input")
(check-equal? (session-focus-vid (ctx-session ctx12)) input-vid "prompt 聚焦 input")
(define ctx13 (type-all ctx12 "new.txt"))
(define ctx14 (step ctx13 (key-event 'enter no-mods)))
(check-true (file-exists? (build-path root "new.txt")) "prompt 新建文件")
(check-false (dock-visible? (workspace-dock (session-workspace (ctx-session ctx14)) 'input)) "提交后 input 隐藏")
(render! ctx14)
(check-true (regexp-match? #rx"new\\.txt" (dock-string ctx14 'tree)) "新建后树刷新")

;; --- 删除（确认） ---
(render! ctx14)
(define lines14 (string-split (dock-string ctx14 'tree) "\n"))
(define new-line (for/first ([l (in-list lines14)] [i (in-naturals)]
                             #:when (regexp-match? #rx"new\\.txt" l)) i))
(define ctx15 (effects! ctx14 (list (e-focus tree-vid)
                                    (e-move tree-vid (selections-one (caret (point new-line 0)))))))
(define ctx16 (step ctx15 (key-event 'backspace no-mods)))
(check-equal? (session-focus-vid (ctx-session ctx16)) input-vid "删除确认进 input")
(define ctx17 (type-all ctx16 "y"))
(define ctx18 (step ctx17 (key-event 'enter no-mods)))
(check-false (file-exists? (build-path root "new.txt")) "确认后删除文件")

;; --- dock 布局 + 尺寸 ---
(define rects (workspace->rectangles (session-workspace (ctx-session ctx18)) 60 14))
(define (rect-of vid) (for/first ([r (in-list rects)] #:when (eqv? vid (rectangle-view-id r))) r))
(check-equal? (rectangle-y (rect-of (workspace-dock-vid (session-workspace (ctx-session ctx18)) 'status)))
              (sub1 (session-height (ctx-session ctx18))) "status 贴底")
(define ctx19 (apply-effect ctx18 (e-dock-resize 'tree 4)))
(check-equal? (dock-size (workspace-dock (session-workspace (ctx-session ctx19)) 'tree)) 28 "dock-resize")

;; --- 关文档清理 path-table ---
(define did-hello (for/first ([d (in-list (editor-document-id-list (session-editor (ctx-session ctx19))))]
                              #:when (equal? "hello.txt" (editor-document-name (session-editor (ctx-session ctx19)) d))) d))
(check-true (doc-open? ctx19 (build-path root "hello.txt")) "hello.txt 已登记")
(define ctx20 (step (effects! ctx19 (list (e-focus (session-edit-vid (ctx-session ctx19)))))
                    (key-event #\q (mods #t #f #f))))
(check-true (session-quit? (ctx-session ctx20)) "Ctrl-Q 退出")

;; --- run-hooks-first：before-insert 拦截（用独立 ctx，避免污染共享 editor）---
(define ctxh0 (app-init root 60 14))
(define (with-hook c name proc) (add-contrib c 'hook name (make-hook 'before-insert proc)))
(define (upcase-effect c args)
  (list (e-type (session-focus-vid (ctx-session c)) (string-upcase (car args)) #f)))
;; #f 不插手 → 默认插入
(define ctxh1 (with-hook ctxh0 'noop (lambda (_c _args) #f)))
(check-equal? (view-string (press ctxh1 #\a)) "a" "before-insert #f → 默认插入")
;; 插手并产 effect → 以 hook 的 effect 为准
(define ctxh2 (with-hook ctxh0 'upcase upcase-effect))
(check-equal? (view-string (press ctxh2 #\b)) "aB" "before-insert effect 覆盖默认")
;; '() 插手但不产 effect → 吞掉输入
(define ctxh3 (with-hook ctxh0 'swallow (lambda (_c _args) '())))
(check-equal? (view-string (press ctxh3 #\c)) "aB" "before-insert '() → 吞掉")

;; --- indent：语法缩进（覆盖 newline），doc-scope 控制适用范围 ---
(check-equal? (indent-for "(define (f" 0 11) 4 "indent-for 嵌套深度")
(define ctxI1 (press (app-init root 60 14) #\())
(check-equal? (view-string (step ctxI1 (key-event 'enter no-mods))) "(\n  )"
              "indent：括号后换行缩进 2")
;; .txt 不适用 → 纯换行
(define ctxI4 (apply-effect (app-init root 60 14) (e-file-open (build-path root "hello.txt") 'replace #t)))
(define ctxI5 (effects! ctxI4 (list (e-nav (session-edit-vid (ctx-session ctxI4)) 'end #f))))
(define ctxI6 (press ctxI5 #\())
(check-equal? (view-string (step ctxI6 (key-event 'enter no-mods))) "hiX(\n)"
              "indent：.txt 不适用 → 纯换行")

;; --- autopair：自动配对（before-insert）---
(define ctxA1 (press (app-init root 60 14) #\())
(check-equal? (view-string ctxA1) "()" "autopair：开括号补闭括号")
(define ctxA2 (press ctxA1 #\)))
(check-equal? (view-string ctxA2) "()" "autopair：右括号不重复插入")
(check-equal? (editor-view-point-column (session-editor (ctx-session ctxA2)) (session-focus-vid (ctx-session ctxA2)))
              2 "autopair：跳过右括号右移")
;; prompt dock 内不配对
(define ctxA3 (apply-effect (app-init root 60 14) (e-prompt "x: " (lambda (_s) '()))))
(define ctxA4 (press ctxA3 #\())
(define in-vid (workspace-dock-vid (session-workspace (ctx-session ctxA4)) 'input))
(check-equal? (editor-view-string (session-editor (ctx-session ctxA4)) in-vid) "x: ("
              "autopair：prompt 内不配对")

;; --- mouse：命中 + 点击定位 ---
(define ctxM0c (type-all (step (type-all (no-complete (app-init root 60 14)) "abc")
                                (key-event 'enter no-mods))
                          "def"))
(define vidM (session-edit-vid (ctx-session ctxM0c)))
(check-equal? (rectangle-view-id (hit-pane ctxM0c 3 0)) vidM "hit-pane 命中主视图")
(define ctxM1 (step ctxM0c (mouse-event 4 2 'press 'left no-mods)))
(check-equal? (session-focus-vid (ctx-session ctxM1)) vidM "鼠标点击聚焦")
(check-equal? (editor-view-point-line (session-editor (ctx-session ctxM1)) vidM) 1 "鼠标点击定位到第 2 行")

;; --- buffers dock：列出 / 切换 ---
(define ctxB0 (apply-effect (app-init root 60 14) (e-file-open (build-path root "hello.txt") 'replace #t)))
(define ctxB1 (press-alt ctxB0 #\b))
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctxB1)) 'buffers)) "Alt-b 显示 buffers")
(render! ctxB1)
(define bufstr (dock-string ctxB1 'buffers))
(check-true (regexp-match? #rx"\\*scratch\\*" bufstr) "buffers 列 scratch")
(check-true (regexp-match? #rx"hello\\.txt" bufstr) "buffers 列 hello.txt")
(define bvid (workspace-dock-vid (session-workspace (ctx-session ctxB1)) 'buffers))
(define ctxB3 (step (effects! ctxB1 (list (e-move bvid (selections-one (caret (point 1 0))))))
                    (key-event 'enter no-mods)))
(render! ctxB3)
(check-true (regexp-match? #rx"view " (dock-string ctxB3 'buffers)) "buffers: 展开显示 view 行")
(define ctxB4 (step (effects! ctxB3 (list (e-move bvid (selections-one (caret (point 2 0))))))
                    (key-event 'enter no-mods)))
(check-equal? (view-string ctxB4) "hiX" "buffers Enter(view) 切到 hello.txt")

;; --- 文件树配色（entry-face）---
(check-equal? (entry-face (entry (build-path root "sub") "sub" #t #f 0) #f) 'tree-dir "目录 face")
(check-equal? (entry-face (entry (build-path root "x.rkt") "x.rkt" #f #f 0) #f) 'tree-file "文件 face")
(check-equal? (entry-face (entry (build-path root "x.rkt") "x.rkt" #f #f 0) #t) 'tree-open "已打开文件 face")
(check-equal? (entry-face (entry (build-path root ".h") ".h" #f #f 0) #f) 'tree-hidden "隐藏文件 face")

;; --- view 管理：view-new / show-view / view-close ---
(define ctxV0 (app-init root 60 14))
(define v0 (session-edit-vid (ctx-session ctxV0)))
(define d0 (editor-view-document-id (session-editor (ctx-session ctxV0)) v0))
(define ctxV1 (apply-effect ctxV0 (e-view-new d0)))
(define v1 (for/first ([v (in-list (editor-document-view-list (session-editor (ctx-session ctxV1)) d0))]
                       #:unless (eqv? v v0)) v))
(check-not-false v1 "e-view-new 新建 view")
(check-false (frame-contains? (workspace-main (session-workspace (ctx-session ctxV1))) v1) "view-new 不放置")
(define ctxV2 (apply-effect ctxV1 (e-show-view v1 #t)))
(check-true (frame-contains? (workspace-main (session-workspace (ctx-session ctxV2))) v1) "show-view 放置")
(check-equal? (session-focus-vid (ctx-session ctxV2)) v1 "show-view 聚焦")
(define ctxV3 (apply-effect ctxV2 (e-view-close v1)))
(check-false (frame-contains? (workspace-main (session-workspace (ctx-session ctxV3))) v1) "view-close 移除")

;; --- pane-swap / pane-resize ---
(define ctxSW0 (press-ctrl (app-init root 60 14) #\l))
(define leaves-before (map leaf-vid (frame-leaves (workspace-main (session-workspace (ctx-session ctxSW0))))))
(define ctxSW1 (apply-effect ctxSW0 (e-pane-swap 'left)))
(define leaves-after (map leaf-vid (frame-leaves (workspace-main (session-workspace (ctx-session ctxSW1))))))
(check-equal? leaves-after (reverse leaves-before) "pane-swap 交换两叶")
(check-not-false (apply-effect ctxSW1 (e-pane-resize 'right)) "pane-resize 不报错")
;; M-m 前缀 → pane-swap
(define ctxPM0 (press-ctrl (app-init root 60 14) #\l))
(define pm-before (map leaf-vid (frame-leaves (workspace-main (session-workspace (ctx-session ctxPM0))))))
(define ctxPM1 (step (press-alt ctxPM0 #\m) (key-event 'left no-mods)))
(check-equal? (map leaf-vid (frame-leaves (workspace-main (session-workspace (ctx-session ctxPM1)))))
              (reverse pm-before) "M-m 前缀 pane-swap")

;; --- dock-cycle：同一侧 dock 轮换（Tab，通用机制）---
(define ctxTL0 (press-ctrl (app-init root 60 14) #\b))     ; C-b 显示 tree 并聚焦
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctxTL0)) 'tree)) "C-b 显示 tree")
(define ctxTL1 (step ctxTL0 (key-event 'tab no-mods)))     ; tree 里 Tab → buffers
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctxTL1)) 'buffers)) "tree 里 Tab 切到 buffers")
(check-false (dock-visible? (workspace-dock (session-workspace (ctx-session ctxTL1)) 'tree)) "tree 里 Tab 隐藏 tree")
(define ctxTL2 (step ctxTL1 (key-event 'tab no-mods)))     ; buffers 里 Tab → tree
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctxTL2)) 'tree)) "buffers 里 Tab 切回 tree")

;; --- prefix（layer）：C-p 入栈，方向键移焦点后出栈 ---
(define ctxP1 (press-ctrl (press-ctrl (app-init root 60 14) #\l) #\p))
(check-not-false (stack-find (session-input (ctx-session ctxP1)) 'prefix) "C-p 入前缀层")
(define focus-before (session-focus-vid (ctx-session ctxP1)))
(define ctxP2 (step ctxP1 (key-event 'left no-mods)))
(check-false (stack-find (session-input (ctx-session ctxP2)) 'prefix) "前缀下一键出栈")
(check-not-equal? (session-focus-vid (ctx-session ctxP2)) focus-before "前缀方向键移动焦点")

;; --- layer 栈：capture / pop / fallthrough / on-enter / set ---
(define cmd-layer-tab
  (lambda (c _ev) (list (e-type (session-focus-vid (ctx-session c)) "T" #f))))

;; capture='all' + pop='next'：层表命中、事件后出栈、阻断 base
(define ctxL
  (no-complete
   (add-contrib
    (add-contrib (app-init root 60 14) 'layer-spec 'test-layer
                 (make-layer 'test-layer
                             #:tables (lambda (_c _i) (list (kbd (key 'tab) 'layer-tab)))
                             #:capture 'all
                             #:pop 'next))
    'command 'layer-tab cmd-layer-tab)))
(define ctxL1 (apply-effect ctxL (e-layer-push 'test-layer 's)))
(check-not-false (stack-top (session-input (ctx-session ctxL1))) "layer 入栈")
(define ctxL2 (step ctxL1 (key-event 'tab no-mods)))
(check-equal? (view-string ctxL2) "T" "capture='all'：层表命中")
(check-false (stack-top (session-input (ctx-session ctxL2))) "pop='next'：事件后出栈")
(define ctxL3 (press (apply-effect ctxL2 (e-layer-push 'test-layer 's)) #\x))
(check-equal? (view-string ctxL3) "T" "capture='all' 阻断 base 输入")

;; fallthrough：base 仍生效，层表优先
(define ctxF
  (no-complete
   (add-contrib
    (add-contrib (app-init root 60 14) 'layer-spec 'fall-layer
                 (make-layer 'fall-layer
                             #:tables (lambda (_c _i) (list (kbd (key 'tab) 'layer-tab)))
                             #:capture 'fallthrough))
    'command 'layer-tab cmd-layer-tab)))
(define ctxF1 (apply-effect ctxF (e-layer-push 'fall-layer 's)))
(define ctxF2 (press ctxF1 #\q))
(check-equal? (view-string ctxF2) "q" "fallthrough：base 输入生效")
(define ctxF3 (step ctxF2 (key-event 'tab no-mods)))
(check-equal? (view-string ctxF3) "qT" "fallthrough：层表优先命中")
(check-not-false (stack-top (session-input (ctx-session ctxF3))) "fallthrough + pop='never'：层仍在")

;; on-enter 产 effect
(define ctxN
  (add-contrib (app-init root 60 14) 'layer-spec 'enter-layer
               (make-layer 'enter-layer
                           #:on-enter (lambda (c _i)
                                        (list (e-type (session-focus-vid (ctx-session c)) "E" #f))))))
(check-equal? (view-string (apply-effect ctxN (e-layer-push 'enter-layer 's))) "E"
              "on-enter 产 effect")

;; e-layer-set 更新状态
(define ctxS
  (add-contrib (app-init root 60 14) 'layer-spec 'state-layer
               (make-layer 'state-layer #:tables (lambda (_c _i) '()))))
(define ctxS1 (apply-effect (apply-effect ctxS (e-layer-push 'state-layer 'a))
                            (e-layer-set 'state-layer 'b)))
(check-equal? (layer-inst-state (stack-find (session-input (ctx-session ctxS1)) 'state-layer))
              'b "e-layer-set 更新状态")

;; --- policy：undo-merge 遇空白断步 ---
(define ctxU1 (type-all (app-init root 60 14) "a b"))
(check-equal? (view-string ctxU1) "a b" "打字 a b")
(define ctxU2 (press-ctrl ctxU1 #\z))
(check-equal? (view-string ctxU2) "a " "undo 去掉 b（空白断步）")
(define ctxU3 (press-ctrl ctxU2 #\z))
(check-equal? (view-string ctxU3) "a" "undo 去掉空格")
(define ctxU4 (press-ctrl ctxU3 #\z))
(check-equal? (view-string ctxU4) "" "undo 去掉 a")

;; --- policy：退出前保存确认 ---
(define ctxQ0 (app-init root 60 14))
(define ctxQ1 (apply-effect ctxQ0 (e-file-open (build-path root "hello.txt") 'replace #t)))
(define ctxQ2 (effects! ctxQ1 (list (e-nav (session-edit-vid (ctx-session ctxQ1)) 'end #f))))
(define ctxQ3 (press ctxQ2 #\Y))
(check-equal? (view-string ctxQ3) "hiXY" "编辑打开的文件")
(define ctxQ4 (press-ctrl ctxQ3 #\q))
(check-false (session-quit? (ctx-session ctxQ4)) "有未保存时先不退出")
(check-true (dock-visible? (workspace-dock (session-workspace (ctx-session ctxQ4)) 'input)) "退出确认弹 prompt")
(define ctxQ5 (step (type-all ctxQ4 "y") (key-event 'enter no-mods)))
(check-true (session-quit? (ctx-session ctxQ5)) "确认 y 后退出")
(check-equal? (file->string (build-path root "hello.txt")) "hiXY" "确认 y 保存了文件")

;; --- face / theme ---
(define (face-colors f) (call-with-values (lambda () (theme-face-colors dark-theme f)) list))
(define (overlay-colors o) (call-with-values (lambda () (theme-overlay-colors dark-theme o)) list))
(check-equal? (face-colors 'state) '((225 225 225) (40 44 52)) "静态 face 配色")
(check-equal? (face-colors (face-compose 'state 'bar)) '((90 96 110) (40 44 52)) "face-stack 分层合并")
(check-equal? (face-colors (palette-color 'word 7)) '((120 180 240) #f) "palette-color 取模")
(check-equal? (overlay-colors 'selection) '(#f (58 74 128)) "overlay 配色")

;; --- overlay / wrap ---
(check-equal? (wrap-line "hello world foo" 8) '("hello" "world" "foo") "wrap-line 空格断行")
(check-equal? (wrap-lines "a\n\nb" 5) '("a" "" "b") "wrap-lines 保留空行")
(define ctxOv
  (add-contrib (app-init root 60 14) 'deco 'test-deco
               (deco 'test-deco
                     (lambda (ctx)
                       (list (frame-pane 't 0 0 3 (list (cons "abc" 'state)) 10))))))
(define ov-panes (overlay-panes ctxOv))
(check-equal? (length ov-panes) 1 "overlay 收 provider pane")
(check-equal? (pane-id (car ov-panes)) 't "pane id")
(check-equal? (call-with-values (lambda () (anchor-placement 0 0 5 3 80 24)) list)
              '(1 0) "anchor 放下方")
(check-equal? (call-with-values (lambda () (anchor-placement 22 0 5 3 80 24)) list)
              '(19 0) "anchor 翻到上方")
(check-equal? (call-with-values (lambda () (anchor-screen-pos ctxOv (session-edit-vid (ctx-session ctxOv)) (point 0 0))) list)
              '(0 2) "anchor-screen-pos")

;; --- async runner + 版本闸门 ---
(define r (make-sync-runner (lambda (req) (* 2 req))))
(define jid (runner-submit! r 21))
(check-equal? (runner-poll! r) (list (cons jid 42)) "sync runner 取回结果")
;; 版本当前 → 交付
(define got (box #f))
(define ctxG (apply-effect ctx0 (e-await 'job1 1 (lambda (_c ver) (= ver 1))
                                         (lambda (_c result) (set-box! got result) '()))))
(check-true (hash-has-key? (session-awaiting (ctx-session ctxG)) 'job1) "await 登记挂起")
(define ctxG2 (apply-effect ctxG (e-deliver 'job1 'ok)))
(check-equal? (unbox got) 'ok "版本闸门：当前版本交付")
(check-false (hash-has-key? (session-awaiting (ctx-session ctxG2)) 'job1) "交付后清空挂起")
;; 版本过期 → 丢弃
(define got2 (box #f))
(define ctxH (apply-effect ctx0 (e-await 'job2 1 (lambda (_c ver) (= ver 2))
                                         (lambda (_c result) (set-box! got2 result) '()))))
(define ctxH2 (apply-effect ctxH (e-deliver 'job2 'stale)))
(check-false (unbox got2) "版本闸门：过期版本丢弃")

;; --- highlight：括号配对纯函数 + before-render 属性写回 ---
(check-equal? (length (bracket-fills "(a (b))" #f)) 2 "bracket-fills 两对")
(call-with-output-file (build-path root "prog.rkt") #:exists 'truncate
  (lambda (o) (display "(define (f) 1)" o)))
(define hl-fills (box #f))
(define ctxHL1 (apply-effect (app-init root 60 14)
                             (e-file-open (build-path root "prog.rkt") 'replace #t)))
(define ctxHL2 (add-contrib ctxHL1 'effect 'attr-highlight
                            (lambda (c did fills combine) (set-box! hl-fills (list did fills)) c)))
(void (app-render ctxHL2))
(check-true (and (pair? (unbox hl-fills)) (pair? (cadr (unbox hl-fills))))
            "highlight：before-render 写回属性")

;; --- complete：自动弹出 + 接受 ---
(define ctxC1 (type-all (app-init root 60 14) "def"))
(check-not-false (stack-find (session-input (ctx-session ctxC1)) 'complete) "打字自动弹补全")
(define ctxC2 (step ctxC1 (key-event 'tab no-mods)))
(check-true (and (regexp-match? #rx"^def" (view-string ctxC2))
                 (> (string-length (view-string ctxC2)) 3))
            "Tab 接受候选")
(check-false (stack-find (session-input (ctx-session ctxC2)) 'complete) "接受后菜单收")

;; --- docs：C-p d 文档浮窗 ---
(call-with-output-file (build-path root "car.rkt") #:exists 'truncate
  (lambda (o) (display "car" o)))
(define ctxD0 (apply-effect (app-init root 60 14) (e-file-open (build-path root "car.rkt") 'replace #t)))
(define ctxD2 (step (press-ctrl ctxD0 #\p) (key-event #\d no-mods)))
(check-not-false (stack-find (session-input (ctx-session ctxD2)) 'docs) "C-p d 弹文档浮窗")
(check-not-false (for/first ([p (in-list (overlay-panes ctxD2))] #:when (eq? (pane-id p) 'docs)) #t)
                 "docs 浮层 pane")

;; --- translate：C-t 前缀 + Up/Down 选拆分方向 ---
(define ctxTU (step (press-ctrl (app-init root 60 14) #\t) (key-event 'up no-mods)))
(check-equal? (split-dir (frame-root (workspace-main (session-workspace (ctx-session ctxTU)))))
              'tb "C-t Up → 水平拆（上下）")
(define ctxT1 (step (press-ctrl (app-init root 60 14) #\t) (key-event 'down no-mods)))
(check-equal? (split-dir (frame-root (workspace-main (session-workspace (ctx-session ctxT1)))))
              'lr "C-t Down → 垂直拆（左右）")
(define tr1 (service-ref ctxT1 'translate))
(check-equal? (length (tr-pairs tr1)) 1 "C-t Down 建立一对")
(check-false (stack-find (session-input (ctx-session ctxT1)) 'translate-split) "选完方向后前缀出栈")
(define tp (car (tr-pairs tr1)))
(define ctxT2 (type-all (apply-effect ctxT1 (e-focus (tpair-src-vid tp))) "printf"))
(check-equal? (editor-view-string (session-editor (ctx-session ctxT2)) (tpair-dst-vid tp))
              "打印" "src→dst 翻译")
(define ctxT3 (press-alt ctxT2 #\t))
(check-equal? (length (tr-pairs (service-ref ctxT3 'translate))) 0 "M-t 关闭配对")

(delete-directory/files root)
(displayln "lab-rebuild smoke: all passed")
