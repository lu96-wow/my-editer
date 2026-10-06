#lang racket

;;; lab-rebuild/smoke.rkt —— 无头冒烟：事件 → 层/base 解析 → 命令 → effect → 会话 → 渲染。

(require rackunit
         "app/app.rkt"
         "builtin/prompt.rkt"
         "kernel/editor-api.rkt"
         "kernel/session.rkt"
         "kernel/runtime.rkt"
         "kernel/binding.rkt"
         "kernel/effect.rkt"
         "kernel/table.rkt"
         "kernel/frame.rkt"
         "kernel/panel.rkt"
         "kernel/paths.rkt"
         "kernel/face.rkt"
         "kernel/render.rkt"
         "kernel/pipeline.rkt")

(define (press ctx ch) (step ctx (key-event ch no-mods)))
(define (press-ctrl ctx ch) (step ctx (key-event ch (mods #t #f #f))))
(define (view-string ctx)
  (editor-view-string (session-editor (ctx-session ctx)) (session-focus-vid (ctx-session ctx))))

(define ctx0 (app-init (current-directory) 40 10))
(define (fresh) (app-init (current-directory) 40 10))

(define vid (session-focus-vid (ctx-session ctx0)))
(check-true (number? vid) "初始有焦点视图")

;; --- 打字 ---
(define ctx1 (press (press ctx0 #\h) #\i))
(check-equal? (view-string ctx1) "hi" "打字进入文档")

;; --- 撤销粒度：连续非空白并成一步 ---
(check-equal? (editor-view-depth (session-editor (ctx-session ctx1)) vid) 1
              "连续打字合并为一步")

;; --- 空白断步 ---
(define ctx2 (press (press ctx1 #\space) #\x))
(check-equal? (view-string ctx2) "hi x")
(check-equal? (editor-view-depth (session-editor (ctx-session ctx2)) vid) 3
              "空白分隔产生多步")

;; --- 退格 ---
(define ctx3 (step ctx2 (key-event 'backspace no-mods)))
(check-equal? (view-string ctx3) "hi ")

;; --- 导航 ---
(define ctx4 (step ctx3 (key-event 'home no-mods)))
(check-equal? (editor-view-point-column (session-editor (ctx-session ctx4)) vid) 0)

;; --- 撤销 / 重做 ---
(define ctx5 (press-ctrl ctx4 #\z))
(check-equal? (view-string ctx5) "hi x" "撤销恢复退格")
(define ctx6 (press-ctrl ctx5 #\y))
(check-equal? (view-string ctx6) "hi " "重做")

;; --- 渲染：状态行 + 正文 ---
(define-values (_ctx7 screen) (app-render ctx6))
(define frame-text (screen->string screen))
(check-true (regexp-match? #rx"hi" frame-text) "帧含正文")
(check-true (regexp-match? #rx"edit" frame-text) "帧含状态行")

;; --- 打开文件 ---
(define tmp (make-temporary-file "lab-rebuild-~a.rkt"))
(call-with-output-file tmp #:exists 'truncate (λ (o) (display "(define x 1)\n" o)))
(define ctx8 (app-open ctx6 (path->string tmp)))
(check-equal? (view-string ctx8) "(define x 1)\n" "打开文件内容")
(delete-file tmp)

;; --- 退出 ---
(define ctx9 (press-ctrl ctx8 #\q))
(check-true (session-quit? (ctx-session ctx9)) "Ctrl+Q 退出")

;;; ================= layer 组合子端到端 =================
(require "kernel/layer.rkt" "kernel/registry.rkt" "kernel/runtime.rkt")

(define test-layer
  (make-layer 'test
              #:capture 'all
              #:pop 'next
              #:tables (λ (ctx inst) (list (kbd (key 'f1) 'noop)))))

(define rt0 (ctx-runtime ctx0))
(define rt2 (make-runtime (reg-add (runtime-registry rt0)
                                   (contrib 'layer-spec 'test 0 test-layer))
                          (runtime-services rt0) (runtime-theme rt0) (runtime-config rt0)))
(define ctxA (ctx (ctx-session ctx0) rt2))

;; 未入栈：F1 无绑定
(define-values (spec0 _o0) (resolve ctxA (key-event 'f1 no-mods)))
(check-false spec0 "未入栈时层不生效")

;; 入栈：capture='all' 屏蔽 base，F1 命中本层
(define ctxB (apply-effects! ctxA (list (e-input-push 'test #f))))
(define-values (spec1 owner1) (resolve ctxB (key-event 'f1 no-mods)))
(check-equal? spec1 'noop "层表生效")
(check-equal? owner1 'test "owner 指向层")

;; pop='next'：处理一个事件后自动出栈
(define ctxC (step ctxB (key-event 'f1 no-mods)))
(check-equal? (input-instances (session-input (ctx-session ctxC))) '() "pop='next' 自动出栈")

;;; ================= prompt（layer + slot + on-blur） =================

(define got (box #f))
(define ctxP0 (apply-effects! ctx0 (list (e-prompt "Test: " #t (λ (v) (set-box! got v) '())))))
(check-equal? (effective-slot-vid ctxP0) (session-input-vid (ctx-session ctx0)) "prompt 占 input 槽位")
(check-equal? (session-focus-vid (ctx-session ctxP0)) (session-input-vid (ctx-session ctx0)) "prompt 聚焦 input")

(define ctxP1 (press (press (press ctxP0 #\a) #\b) #\c))
(define ctxP2 (step ctxP1 (key-event 'enter no-mods)))
(check-equal? (unbox got) "abc" "prompt 提交回传输入")
(check-equal? (input-instances (session-input (ctx-session ctxP2))) '() "prompt 提交后出栈")
(check-equal? (session-focus-vid (ctx-session ctxP2)) vid "prompt 提交后焦点还原")

;; on-blur：焦点离开 input → 自动取消
(define ctxB0 (apply-effects! ctx0 (list (e-prompt "X: " #t (λ (v) '())))))
(define ctxB1 (apply-effects! ctxB0 (list (e-focus vid))))
(define ctxB2 (step ctxB1 (key-event 'f5 no-mods)))
(check-equal? (input-instances (session-input (ctx-session ctxB2))) '() "失焦自动取消 prompt")

;;; ================= 退出前保存确认（Interaction 挂起 / 续做） =================

(require racket/file)
(define tmp2 (make-temporary-file "lab-rebuild-save-~a.rkt"))
(call-with-output-file tmp2 #:exists 'truncate (λ (o) (display "abc" o)))
(define ctxF (app-open ctx0 (path->string tmp2)))
(define ctxF1 (press ctxF #\X))              ; 改脏
(define ctxF2 (press-ctrl ctxF1 #\q))        ; quit → policy 拦成询问
(check-false (session-quit? (ctx-session ctxF2)) "quit 被拦成询问")
(check-equal? (effective-slot-vid ctxF2) (session-input-vid (ctx-session ctxF2)) "询问占 input")
;; 答 "n" + Enter → 跳过保存，继续退出
(define ctxF3 (step (step ctxF2 (key-event #\n no-mods)) (key-event 'enter no-mods)))
(check-true (session-quit? (ctx-session ctxF3)) "跳过保存后退出")
(check-equal? (file->string tmp2) "abc" "未保存时盘上仍是旧内容")
(delete-file tmp2)

;; 多文件：逐次答 n，最后一答才退出；挂起整个多步链上保持可枚举、结束清理
(define tmpA (make-temporary-file "lab-rebuild-qa-~a.rkt"))
(define tmpB (make-temporary-file "lab-rebuild-qb-~a.rkt"))
(for ([f (list tmpA tmpB)]) (call-with-output-file f #:exists 'truncate (λ (o) (display "z" o))))
(define ctxQA (press (app-open (fresh) (path->string tmpA)) #\A))
(define ctxQB (press (app-open ctxQA (path->string tmpB)) #\B))
(define ctxQ1 (press-ctrl ctxQB #\q))
(check-equal? (length (session-interactions (ctx-session ctxQ1))) 1 "挂起登记 1 条")
(define ctxQ2 (step (step ctxQ1 (key-event #\n no-mods)) (key-event 'enter no-mods)))
(check-false (session-quit? (ctx-session ctxQ2)) "第一答不退出（还有下一个文件）")
(check-equal? (length (session-interactions (ctx-session ctxQ2))) 1 "多步链仍同一挂起")
(define ctxQ3 (step (step ctxQ2 (key-event #\n no-mods)) (key-event 'enter no-mods)))
(check-true (session-quit? (ctx-session ctxQ3)) "最后一答才退出")
(check-equal? (length (session-interactions (ctx-session ctxQ3))) 0 "退出后挂起清理")
;; esc 取消：结束挂起但不退出
(define ctxQ4 (press-ctrl ctxQB #\q))
(define ctxQ5 (step ctxQ4 (key-event 'escape no-mods)))
(check-false (session-quit? (ctx-session ctxQ5)) "esc 不退出")
(check-equal? (length (session-interactions (ctx-session ctxQ5))) 0 "esc 也结束挂起")
(delete-file tmpA) (delete-file tmpB)

;;; ================= 分屏 / 焦点方向 =================
(define ctxS1 (press-ctrl ctx0 #\l))          ; split-lr
(define leaves1 (frame-leaves (session-frame (ctx-session ctxS1))))
(check-equal? (length leaves1) 2 "split 产生两个叶")
(check-equal? (session-focus-vid (ctx-session ctxS1)) (leaf-vid (cadr leaves1)) "焦点在新窗格")
(define ctxS2 (apply-effects! ctxS1 (list (e-focus (list 'dir 'left)))))
(check-equal? (session-focus-vid (ctx-session ctxS2)) (leaf-vid (car leaves1)) "方向移动焦点")
(define ctxS3 (press-ctrl ctxS1 #\d))          ; pane-close（关当前）
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxS3)))) 1 "关窗格")

;;; ================= 面板 / 侧栏 =================
(check-equal? (length (session-panels (ctx-session ctx0))) 2 "有 tree + buffers 面板")
(check-false (session-sidebar? (ctx-session ctx0)) "侧栏默认隐藏")
(define ctxPan1 (press-ctrl ctx0 #\b))
(check-true (session-sidebar? (ctx-session ctxPan1)) "侧栏显示")
(check-equal? (session-focus-vid (ctx-session ctxPan1))
              (panel-vid (car (session-panels (ctx-session ctxPan1)))) "焦点到面板")
(define-values (_c1 scr) (app-render ctxPan1))
(check-true (regexp-match? #rx"core" (screen->string scr)) "侧栏渲染文件树")
;; Tab 在面板间轮换（tree ↔ buffers）
(define ctxPanT (step ctxPan1 (key-event 'tab no-mods)))
(check-equal? (session-active-panel (ctx-session ctxPanT)) 'buffers "Tab 轮换到 buffers")
(define-values (_ct scrT) (app-render ctxPanT))
(check-true (regexp-match? #rx"scratch" (screen->string scrT)) "buffers 显示文档列表")
(define ctxPan2 (press-ctrl ctxPan1 #\b))
(check-false (session-sidebar? (ctx-session ctxPan2)) "侧栏隐藏")
(check-equal? (session-focus-vid (ctx-session ctxPan2)) vid "隐藏后焦点还原")

;; 侧栏展开时方向焦点：覆盖 panel rect + shown-panel（active=buffers）选择
(define ctxFx0 ctxPanT)                                        ; active=buffers，焦点在 buffers
(define fx-panel (panel-vid (shown-panel (session-panels (ctx-session ctxFx0))
                                         (session-active-panel (ctx-session ctxFx0)))))
(check-equal? (session-focus-vid (ctx-session ctxFx0)) fx-panel "焦点在 buffers 面板")
(define ctxFx1 (apply-effects! ctxFx0 (list (e-focus (list 'dir 'right)))))
(check-true (frame-contains? (session-frame (ctx-session ctxFx1))
                             (session-focus-vid (ctx-session ctxFx1)))
            "方向焦点：面板 → 主区")
(define ctxFx2 (apply-effects! ctxFx1 (list (e-focus (list 'dir 'left)))))
(check-equal? (session-focus-vid (ctx-session ctxFx2)) fx-panel
              "方向焦点：主区 → buffers 面板（不是 tree）")

;;; ================= 状态行：显示活动编辑视图（vN），不被面板焦点带跑 =================
(require "builtin/status.rkt")
(check-true (regexp-match? #rx"edit v[0-9]+" (status-text ctx0)) "状态行显示编辑视图 id")
(check-true (regexp-match? #rx"edit v[0-9]+" (status-text ctxPan1))
            "面板焦点下状态行仍显示编辑视图")
(check-true (regexp-match? #rx"tree \\|" (status-text ctxPan1)) "状态行前缀提示面板焦点")
(check-true (regexp-match? #rx"buffers \\|" (status-text ctxPanT)) "状态行前缀提示 buffers 焦点")

;;; ================= 鼠标（同一 resolve） =================
(check-equal? (rectangle-view-id (hit-pane ctx0 3 0)) vid "鼠标命中主视图")
(check-equal? (rectangle-view-id (hit-pane ctxPan1 3 0))
              (panel-vid (car (session-panels (ctx-session ctxPan1)))) "鼠标命中面板")
(define ctxM1 (press ctx0 #\a))                                  ; 打字自动弹补全
(define ctxM2 (step ctxM1 (key-event 'escape no-mods)))          ; Esc 取消菜单
(define ctxM3 (step ctxM2 (key-event 'enter no-mods)))           ; 无菜单时 Enter 换行
(define ctxM4 (step (press ctxM3 #\b) (key-event 'escape no-mods)))  ; 第二行 + 取消
(define ctxM (step ctxM4 (mouse-event 5 2 'press 'left no-mods)))
(check-equal? (session-focus-vid (ctx-session ctxM)) vid "鼠标点击聚焦")
(check-equal? (editor-view-point-line (session-editor (ctx-session ctxM)) vid) 1 "鼠标点击定位行")

;;; ================= 前缀层 / 窗格调换 =================
(define ctxPre0 (step ctx0 (key-event #\p (mods #t #f #f))))   ; C-p
(check-equal? (length (input-instances (session-input (ctx-session ctxPre0)))) 1 "C-p 入栈")
(define-values (_cp scrP) (app-render ctxPre0))
(check-true (regexp-match? #rx"C-p" (screen->string scrP)) "状态行显示前缀")
(define ctxPre1 (step ctxPre0 (key-event 'right no-mods)))
(check-equal? (input-instances (session-input (ctx-session ctxPre1))) '() "前缀下一键后退出")

(define ctxSw0 (press-ctrl ctx0 #\l))
(define vids-before (map leaf-vid (frame-leaves (session-frame (ctx-session ctxSw0)))))
(define ctxSw1 (apply-effects! ctxSw0 (list (e-pane-swap 'left))))
(define vids-after (map leaf-vid (frame-leaves (session-frame (ctx-session ctxSw1)))))
(check-equal? vids-after (reverse vids-before) "swap 交换两叶")
(define ctxRz (apply-effects! ctxSw1 (list (e-pane-resize 'right))))
(check-true (number? (session-width (ctx-session ctxRz))) "resize 不报错")

;;; ================= 剪贴板 / indent / autopair =================
(define ctxT (press (press (press (fresh) #\a) #\b) #\c))
(define ctxSel (step ctxT (key-event 'a (mods #t #f #f))))
(define ctxCop (step ctxSel (key-event 'c (mods #t #f #f))))
(define ctxP (step (step ctxCop (key-event 'end no-mods)) (key-event #\v (mods #t #f #f))))
(check-equal? (view-string ctxP) "abcabc" "复制 + 粘贴")

(define ctxAp (press (fresh) #\())
(check-equal? (view-string ctxAp) "()" "autopair 补右括号")
(check-equal? (view-string (press ctxAp #\x)) "(x)" "autopair 中间输入")

(define ctxI (press (press (fresh) #\() #\x))
(define ctxI2 (step (step ctxI (key-event 'escape no-mods)) (key-event 'enter no-mods)))
(check-true (regexp-match? #rx"\n  " (view-string ctxI2)) "Enter 按括号缩进两格")

;;; ================= 属性高亮（版本闸门 + 分层写回） =================
(define tmpH (make-temporary-file "lab-rebuild-hl-~a.rkt"))
(call-with-output-file tmpH #:exists 'truncate (λ (o) (display "(define x 1)\n" o)))
(define ctxH (app-open (fresh) (path->string tmpH)))
(define didH (path-table-did (session-paths (ctx-session ctxH)) (path->string tmpH)))
(define-values (_ctxH1 _scrH) (app-render ctxH))     ; before-render 触发高亮 sync+poll
(check-true (editor-document-highlight-range? (session-editor (ctx-session ctxH)) didH 0 0 0 15)
            "高亮写回（真实文件）")
(check-true (face-stack? (document-highlight-at (editor-document-handle (session-editor (ctx-session ctxH)) didH) 0 1))
            "词色 + 关键字色分层")
;; 编辑后再渲染：走 machine-change! 增量同步
(define ctxH2 (press ctxH #\space))
(define-values (_h2 _s2) (app-render ctxH2))
(check-true (editor-document-highlight-range? (session-editor (ctx-session ctxH2)) didH 0 0 0 6)
            "增量同步后高亮仍在")
(delete-file tmpH)

;;; ================= 属性插件：按文档过滤启用 =================
(require "builtin/highlight/registry.rkt" "builtin/highlight/api.rkt" "builtin/highlight/machine.rkt")
(define (names ps) (map plugin-name ps))
(check-equal? (names (plugins-for enabled-attr-plugins (string->path "/tmp/a.rkt") "(define x 1)"))
              '(brackets words syntax) ".rkt 启用全部插件")
(check-equal? (names (plugins-for enabled-attr-plugins (string->path "/tmp/a.txt") "hello"))
              '() ".txt 不启用任何插件（均 applies? = .rkt）")
(check-equal? (names (plugins-for enabled-attr-plugins #f "hello"))
              '() "无路径不启用任何插件")
;; machine 按文档存适用插件集
(define hmach (make-machine enabled-attr-plugins))
(machine-open! hmach 1 0 (string->path "/tmp/a.txt") "hello (world)")
(check-equal? (names (machine-plugins-for hmach 1)) '() "machine 按文档过滤（.txt 空集）")
(machine-open! hmach 2 0 (string->path "/tmp/a.rkt") "(define x 1)")
(check-equal? (names (machine-plugins-for hmach 2)) '(brackets words syntax) "machine .rkt 全启用")

;;; ================= 补全（打字自动弹 + deco 浮层 + layer） =================
(define ctxC0 (press (press (press (fresh) #\d) #\e) #\f))
(check-equal? (length (input-instances (session-input (ctx-session ctxC0)))) 1 "打字自动弹补全")
(define-values (_cc0 scrC0) (app-render ctxC0))
(check-true (regexp-match? #rx"define" (screen->string scrC0)) "自动弹菜单显示候选")
(define ctxC1 (step ctxC0 (key-event #\n (mods #t #f #f))))   ; C-n 显式刷新
(check-equal? (length (input-instances (session-input (ctx-session ctxC1)))) 1 "C-n 不重复入栈")
(define-values (_cc scrC) (app-render ctxC1))
(check-true (regexp-match? #rx"define" (screen->string scrC)) "菜单显示候选")
(define ctxC2 (step ctxC1 (key-event 'tab no-mods)))          ; accept
(check-true (string-prefix? (view-string ctxC2) "def") "接受候选（前缀保留）")
(check-true (> (string-length (view-string ctxC2)) 3) "接受候选（变长）")
(check-equal? (input-instances (session-input (ctx-session ctxC2))) '() "接受后出栈")

;;; ================= 补全：模块感知 + 内嵌 bluebox 文档 =================
(require "builtin/complete.rkt" "builtin/lang/docs.rkt")
(define cdir (make-temporary-file "lab-cpl-~a" 'directory))
(define cfile (build-path cdir "sample.rkt"))
(call-with-output-file cfile #:exists 'truncate
  (λ (o) (display "#lang racket\n(require racket/list)\nsecon" o)))
(define ctxMC (app-open (app-init (path->string cdir) 40 10) (path->string cfile)))
(define mcvid (session-focus-vid (ctx-session ctxMC)))
(define ctxMC0 (apply-effects! ctxMC (list (e-move mcvid (selections-one (caret (point 2 5)))))))
(define ctxMC1 (step ctxMC0 (key-event #\n (mods #t #f #f))))   ; C-n
(define mc-inst (input-find (session-input (ctx-session ctxMC1)) 'complete))
(check-true (and mc-inst (if (member "second" (cs-cands (layer-inst-state mc-inst))) #t #f))
            "候选池含 #lang/require 模块导出（racket/list）")
(define ctxMC2 (run-notify ctxMC1 'job-tick '()))               ; 异步结果 → e-deliver
(define mc-st (layer-inst-state (input-find (session-input (ctx-session ctxMC2)) 'complete)))
(check-true (doc? (cs-doc mc-st)) "补全选中项内嵌 bluebox 文档已装")
(define-values (_mcc scrMC) (app-render ctxMC2))
(check-true (regexp-match? #rx"second" (screen->string scrMC)) "补全菜单渲染")
(delete-directory/files cdir)

;;; ================= 补全：非 Racket 文件不启用 =================
(define cgdir (make-temporary-file "lab-cgate-~a" 'directory))
(define cgfile (build-path cgdir "a.c"))
(call-with-output-file cgfile #:exists 'truncate (λ (o) (display "int main(){}\n" o)))
(define ctxCG0 (app-open (app-init (path->string cgdir) 40 10) (path->string cgfile)))
(define cgv (session-focus-vid (ctx-session ctxCG0)))
(define ctxCG1 (apply-effects! ctxCG0 (list (e-move cgv (selections-one (caret (point 0 5)))))))
(define ctxCG2 (press (press ctxCG1 #\d) #\e))
(check-equal? (length (input-instances (session-input (ctx-session ctxCG2)))) 0 "a.c 打字不弹补全")
(define ctxCG3 (step ctxCG2 (key-event #\n (mods #t #f #f))))
(check-equal? (length (input-instances (session-input (ctx-session ctxCG3)))) 0 "a.c C-n 不弹补全")
(delete-directory/files cgdir)

;;; ================= 浮层落位：不覆盖锚点行（顶行刚好放得下 → 放下方） =================
(require "kernel/overlay.rkt")
(define-values (fp-top _fl) (anchor-placement 0 5 40 11 60 12))
(check-true (> fp-top 0) "浮层不覆盖锚点行")
(define-values (fp-top2 _fl2) (anchor-placement 10 5 40 8 60 12))
(check-equal? fp-top2 2 "下方放不下 → 翻上方且不覆盖锚点")

;;; ================= 异步版本闸门（内核统一） =================
(define gotG (box #f))
(define ctxAw (apply-effects! (fresh) (list (e-await 'j1 1 (λ (c v) #t) (λ (c r) (set-box! gotG r) '())))))
(define _aw1 (apply-effects! ctxAw (list (e-deliver 'j1 42))))
(check-equal? (unbox gotG) 42 "闸门：版本命中则回调")
(define gotG2 (box #f))
(define ctxAw2 (apply-effects! (fresh) (list (e-await 'j2 1 (λ (c v) #f) (λ (c r) (set-box! gotG2 r) '())))))
(define _aw2 (apply-effects! ctxAw2 (list (e-deliver 'j2 42))))
(check-false (unbox gotG2) "闸门：迟到结果丢弃")

;;; ================= docs 浮层（deco frame） =================
(require "builtin/docs.rkt")
(define dvid (session-focus-vid (ctx-session ctx0)))
(define fake-docs (docs dvid (point 0 0) (list->vector (list "hello docs" "second line")) 0 12 5 "x"))
(define ctxDoc (apply-effects! (fresh) (list (e-input-push 'docs fake-docs))))
(check-true (docs? (layer-inst-state (input-find (session-input (ctx-session ctxDoc)) 'docs))) "docs 层")
(define-values (_cd scrD) (app-render ctxDoc))
(check-true (regexp-match? #rx"hello docs" (screen->string scrD)) "docs 浮层渲染")

;;; ================= 文件树 Enter 打开文件 =================
(define tdir (make-temporary-file "lab-treedir-~a" 'directory))
(call-with-output-file (build-path tdir "hello.txt") #:exists 'truncate (lambda (o) (display "hi tree" o)))
(define ctxTD (app-init (path->string tdir) 40 10))
(define ctxTD1 (step ctxTD (key-event #\b (mods #t #f #f))))   ; 侧栏 + 焦点到 tree
(define-values (ctxTD1r _scrTD) (app-render ctxTD1))          ; 先渲染：面板内容在此刷新
(define tv (session-focus-vid (ctx-session ctxTD1r)))
(check-equal? tv (panel-vid (car (session-panels (ctx-session ctxTD1r)))) "焦点在 tree 面板")
(define ctxTD2 (apply-effects! ctxTD1r (list (e-move tv (selections-one (caret (point 1 0)))))))
(define ctxTD3 (step ctxTD2 (key-event 'enter no-mods)))
(check-equal? (view-string ctxTD3) "hi tree" "文件树 Enter 打开文件")
(delete-directory/files tdir)

;;; ================= 文档/视口树（buffers 两级） =================
(define ctxBV0 (fresh))
(define ctxBV1 (step ctxBV0 (key-event #\b (mods #t #f #f))))   ; 侧栏（默认 tree）
(define ctxBV2 (step ctxBV1 (key-event 'tab no-mods)))          ; 轮到 buffers
(check-equal? (session-active-panel (ctx-session ctxBV2)) 'buffers "轮到 buffers")
(define-values (ctxBV3 _sB) (app-render ctxBV2))
(define bv (session-focus-vid (ctx-session ctxBV3)))
(define (scratch-did ctx)
  (define ed (session-editor (ctx-session ctx)))
  (for/first ([d (in-list (editor-document-id-list ed))]
              #:when (equal? "*scratch*" (editor-document-name ed d))) d))
(define didS (scratch-did ctxBV3))
(define views0 (length (editor-document-view-list (session-editor (ctx-session ctxBV3)) didS)))
(define ctxBV4 (step (apply-effects! ctxBV3 (list (e-move bv (selections-one (caret (point 0 0))))))
                     (key-event #\n (mods #t #f #f))))          ; C-n 新建视图
(check-equal? (length (editor-document-view-list (session-editor (ctx-session ctxBV4)) didS))
              (add1 views0) "C-n 新建视图")
(define-values (ctxBV5 _sB2) (app-render ctxBV4))
(define ctxBV6 (step (apply-effects! ctxBV5 (list (e-move bv (selections-one (caret (point 1 0))))))
                     (key-event 'backspace no-mods)))           ; Backspace 关闭视图
(check-equal? (length (editor-document-view-list (session-editor (ctx-session ctxBV6)) didS))
              views0 "Backspace 关闭视图")

;;; ================= 布局：buffers 选中 view 后分屏插入 / 不塔掉分屏 =================
(define ctxLV0 (press-ctrl (fresh) #\l))                 ; 编辑区先分屏（2 叶）
(define lv-main (session-focus-vid (ctx-session ctxLV0)))
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxLV0)))) 2 "初始 2 叶")
(define ctxLV1 (press-ctrl ctxLV0 #\b))                  ; 侧栏 → tree
(define ctxLV2 (step ctxLV1 (key-event 'tab no-mods)))    ; → buffers
(define-values (ctxLV3 _sLV) (app-render ctxLV2))
(define lv-bufs (session-focus-vid (ctx-session ctxLV3)))
(define ctxLV4 (press-ctrl ctxLV3 #\n))                  ; C-n 新建（未入布局）视图
(define-values (ctxLV5 _sLV2) (app-render ctxLV4))
;; Enter：只替换活动编辑叶，不塔掉 2 叶分屏（旧 bug：frame-set-root → 1 叶）
(define ctxLV6 (step (apply-effects! ctxLV5 (list (e-move lv-bufs (selections-one (caret (point 2 0))))))
                     (key-event 'enter no-mods)))
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxLV6)))) 2 "Enter 不塔分屏")
(check-true (frame-contains? (session-frame (ctx-session ctxLV6)) lv-main) "Enter 保留原叶")
;; C-l：把选中的 view 分屏插入（叶 +1）
(define ctxLV7 (press-ctrl ctxLV6 #\n))                  ; 又一个未入布局视图
(define-values (ctxLV8 _sLV3) (app-render ctxLV7))
(define ctxLV9 (apply-effects! ctxLV8 (list (e-move lv-bufs (selections-one (caret (point 3 0)))))))
(define ctxLV10 (step ctxLV9 (key-event 'l (mods #t #f #f))))   ; C-l
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxLV10)))) 3 "C-l 分屏插入新叶")
(check-true (frame-contains? (session-frame (ctx-session ctxLV10)) lv-main) "C-l 保留原叶")
(check-true (frame-contains? (session-frame (ctx-session ctxLV10))
                             (session-focus-vid (ctx-session ctxLV10))) "C-l 焦点在新叶")

;;; ================= 保存询问：焦点/光标置到输入视图（长 label 可左右滚） =================
(define tdir2 (make-temporary-file "lab-long-~a" 'directory))
(define longname2 (string-append (make-string 60 #\a) ".rkt"))
(define fpath2 (build-path tdir2 longname2))
(call-with-output-file fpath2 #:exists 'truncate (lambda (o) (display "x" o)))
(define ctxSV (app-open (app-init (path->string tdir2) 40 10) fpath2))
(define ctxSV1 (press ctxSV #\X))                              ; 弄脏
(define ctxSV2 (step ctxSV1 (key-event #\q (mods #t #f #f))))  ; Ctrl-Q → 保存询问
(define sSV (ctx-session ctxSV2))
(check-equal? (session-focus-vid sSV) (session-input-vid sSV) "保存询问焦点在 input 视图")
(check-true (> (editor-view-point-column (session-editor sSV) (session-input-vid sSV)) 40)
            "光标在长 label 末尾")
(check-true (> (editor-view-left-column (session-editor sSV) (session-input-vid sSV)) 0)
            "视口横向滚动到光标")
(define ctxSV3 (step ctxSV2 (key-event 'home no-mods)))
(check-equal? (editor-view-left-column (session-editor (ctx-session ctxSV3))
                                       (session-input-vid (ctx-session ctxSV3)))
              0 "Home 滚回开头")
(delete-directory/files tdir2)

;;; ================= patch 路径：布局尺寸生效 → 视口跟随光标 =================
(define fL (make-temporary-file "lab-long-~a.rkt"))
(call-with-output-file fL #:exists 'truncate (lambda (o) (display (make-string 200 #\z) o)))
(define ctxL (app-open (app-init (current-directory) 40 10) fL))
(define lv (session-focus-vid (ctx-session ctxL)))
(define ctxL2 (apply-effects! ctxL (list (e-session-size 20 10))))   ; 缩窗
(define-values (ctxL3 _nL _rL _sL) (app-render-patch ctxL2 #f))      ; TUI 走 patch
(define ctxL4 (step ctxL3 (key-event 'end no-mods)))
(check-true (> (editor-view-left-column (session-editor (ctx-session ctxL4)) lv) 170)
            "patch 路径：视口尺寸生效、跟随光标")
(delete-file fL)

(displayln "smoke: all passed")
