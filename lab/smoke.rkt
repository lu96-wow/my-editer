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

;;; ================= doc-scope：按文档启用（补全/文档/缩进的单一来源） =================
(require "builtin/doc-scope.rkt")
(define sd (make-temporary-file "lab-scope-~a" 'directory))
(define sc (build-path sd "a.c"))
(call-with-output-file sc #:exists 'truncate void)
(define ctxSC (app-open (app-init (path->string sd) 40 10) (path->string sc)))
(check-false (doc-applies? ctxSC 'complete) ".c complete 关")
(check-false (doc-applies? ctxSC 'docs) ".c docs 关")
(check-false (doc-applies? ctxSC 'indent) ".c indent 关")
(define ctxSCI (step (press ctxSC #\() (key-event 'enter no-mods)))
(check-equal? (view-string ctxSCI) "(\n)" ".c 换行不缩进")
(delete-directory/files sd)
(define sr (make-temporary-file "lab-scope-r-~a.rkt"))
(call-with-output-file sr #:exists 'truncate void)
(define ctxSR (app-open (app-init (current-directory) 40 10) (path->string sr)))
(check-true (doc-applies? ctxSR 'complete) ".rkt complete 开")
(check-true (doc-applies? ctxSR 'docs) ".rkt docs 开")
(check-true (doc-applies? ctxSR 'indent) ".rkt indent 开")
(define ctxSRI (step (press ctxSR #\() (key-event 'enter no-mods)))
(check-equal? (view-string ctxSRI) "(\n  )" ".rkt 换行缩进")
(delete-file sr)
(check-true (doc-applies? (fresh) 'complete) "scratch 允许")

;;; ================= require 模块路径补全 =================
(require "builtin/lang/source.rkt" "builtin/lang/module-index.rkt" "builtin/lang/complete.rkt")
(define (rc s) (require-context? s 0 (string-length s)))
(check-true (rc "(require racket/l") "require 上下文")
(check-true (rc "(require (only-in racket/l") "包装器第一参数 = 模块")
(check-false (rc "(require (only-in racket/list sec") "包装器第二参数 = 标识符")
(check-false (rc "(define x 1") "非 require 上下文")
(check-true (and (member "racket/list" (force module-paths)) #t) "模块索引含 racket/list")
(define (type-all ctx s) (for/fold ([c ctx]) ([ch (in-string s)]) (press c ch)))
(define ctxRQ (type-all (fresh) "(require racket/l"))
(define rq-inst (input-find (session-input (ctx-session ctxRQ)) 'complete))
(check-true (and rq-inst (if (member "racket/list" (cs-cands (layer-inst-state rq-inst))) #t #f))
            "require 补全出 racket/list")

;;; ================= 模块上下文严格 = #lang + require（不越界到 racket） =================
(define (pool-has? text name)
  (and (member name (completion-pool #:modules (source-requires text))) #t))
(check-false (pool-has? "#lang racket/base\n" "second") "#lang racket/base 不含 second")
(check-true (pool-has? "#lang racket\n" "second") "#lang racket 含 second")
(check-true (pool-has? "#lang racket/base\n(require racket/list)\n" "second")
            "(require racket/list) 后含 second")
;; `#lang` 不必在第一行：空行 / 行注释 / 块注释 / `#;` 数据注释 / shebang 之后都要认
;; （与 Racket 编译器一致：这些 trivia 可以有任意多个）。
(check-true (pool-has? "\n\n#lang racket\n" "second") "空行后的 #lang 被识别")
(check-true (pool-has? (string-append (make-string 50 #\newline) "#lang racket\n") "second")
            "任意多空行后的 #lang 被识别")
(check-true (pool-has? ";; c\n#lang racket\n" "second") "行注释后的 #lang 被识别")
(check-true (pool-has? "#| c #| nested |# c |#\n#lang racket\n" "second") "块注释后的 #lang 被识别")
(check-true (pool-has? "#;1 #;(a b)\n\n;; c\n#|x|#\n#lang racket\n" "second") "#; 数据注释后的 #lang 被识别")
(check-true (pool-has? "#!/usr/bin/env racket\n#lang racket\n" "second") "shebang 后的 #lang 被识别")
;; 无 #lang 的顶层 (module name lang …) 也是合法模块（loader 支持）。
(check-true (pool-has? "(module m racket\n  (provide x)\n  (define x 1))\n" "second")
            "顶层 module 的语言被识别")
(check-true (and (member 'x (source-definitions "(module m racket\n  (define x 1))\n")) #t)
            "module 体里的定义被识别")
(check-true (and (member 'y (source-definitions "\n\n#lang racket\n(define y 1)\n")) #t)
            "空行后的 #lang 之后定义被识别")

;;; ================= 词补全（复用共享词法器 lang/lex） =================
(require "builtin/lang/lex.rkt")
;; 共享词法：与高亮词色同一套（foo_bar 是一个词，$ 在前缀里也算词字符）。
(check-equal? (map cadddr (scan-words "foo_bar baz$qux"))
              '("foo_bar" "baz$qux") "lex：标识符含 _ 与 $")
(check-equal? (document-words "(define foobar 1) fo fo")
              '("define" "foobar" "fo") "document-words：去重、滤 1 字符")
(check-equal? (document-words "id x id") '("id") "document-words：默认 min-length 2")
(check-true (if (member "foobar"
                    (completion-pool #:words (document-words "(define foobar 1)")))
                #t #f)
            "补全池含出现过的词")
;; 集成：先把定义打进文件，再打前缀，菜单应含文件里的词。
(define ctxWD (type-all (fresh) "(define foobar 1)\nfoo"))
(define wd-inst (input-find (session-input (ctx-session ctxWD)) 'complete))
(check-true (and wd-inst (if (member "foobar" (cs-cands (layer-inst-state wd-inst))) #t #f))
            "菜单含文件里出现过的词 foobar")

;;; ================= 增量词表 / 每文档候选池 =================
(require "builtin/lang/word-index.rkt")
;; 纯：整篇建 + 增量加词
(define wi0 (word-index-open "(define foobar 1)\n"))
(check-true (and (member "foobar" (word-index-words wi0)) #t) "word-index：建表含 foobar")
(define added0 (word-index-change wi0 (list (list 1 0 1 0 "baz"))))
(check-true (and (member "baz" added0) #t) "word-index：增量返回新词 baz")
(check-true (and (member "baz" (word-index-words wi0)) #t) "word-index：增量后含 baz")
(define (menu-has? ctx name)
  (define inst (input-find (session-input (ctx-session ctx)) 'complete))
  (and inst (if (member name (cs-cands (layer-inst-state inst))) #t #f)))
(check-true (menu-has? ctxWD "foobar") "增量词表：定义后仍能补出 foobar")
;; header 新增 require → 每 did 池失效并重建，应补出新 require 的导出
(define ctxHR (type-all (fresh) "(require racket/list)\nsec"))
(check-true (menu-has? ctxHR "second") "header 新增 require → 补出 second")
;; 多行 require：require-context 的窗口仍能识别
(define ctxML (type-all (fresh) "(require\n  racket/l"))
(check-true (menu-has? ctxML "racket/list") "多行 require 仍是模块上下文")

;;; ================= 前导空行不能让「行号」移位（line-at / prefix-at） =================
;; racket/string 的 string-split 默认 #:trim? #t 会吞掉首个空行，导致所有行号偏 1：
;; 以空行开头的文件（如 a.rkt）补全/缩进全错位。这几条是回归测试。
(require "builtin/lang/ident.rkt" "builtin/indent.rkt")
(check-equal? (line-at "\n\nfoo" 2) "foo" "line-at：前导空行不移位")
(check-equal? (prefix-at "\n\n(define )" 2 7) "define" "prefix-at：前导空行不移位")
(check-equal? (indent-for "\n\n(define (f\n" 3 0) 4 "indent：前导空行不移位")
;; 集成：打开一个以空行开头的 .rkt，在 (define ) 里打字应弹补全。
(define lbdir (make-temporary-file "lab-leadblank-~a" 'directory))
(define lbf (build-path lbdir "a.rkt"))
(call-with-output-file lbf #:exists 'truncate
  (λ (o) (display "\n\n#lang racket/base\n\n(define )\n" o)))
(define ctxLB (app-open (app-init (path->string lbdir) 40 10) (path->string lbf)))
(define lbvid (session-focus-vid (ctx-session ctxLB)))
(define ctxLB2 (apply-effects! ctxLB (list (e-move lbvid (selections-one (caret (point 4 8)))))))
(define ctxLB3 (press ctxLB2 #\s))
(define lb-inst (input-find (session-input (ctx-session ctxLB3)) 'complete))
(check-true (and lb-inst (pair? (cs-cands (layer-inst-state lb-inst))))
            "以空行开头的文件里打字弹补全")
(delete-directory/files lbdir)

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

;;; ================= 对照翻译（内容双向 + 视口同步） =================
(require "builtin/translate.rkt")
(define tdict (for/hash ([p (in-list (list (cons "printf" "打印") (cons "display" "显示")))]) (values (car p) (cdr p))))
(check-equal? (translate-string tdict "printf(x);\ndisplay(y);\n") "打印(x);\n显示(y);\n"
              "整词翻译保持空白 / 换行")
(check-equal? (translate-string tdict "printf_safe") "printf_safe" "不匹配子串")

(define ctxTR0 (type-all (fresh) "printf(a);\ndisplay(b);\nprintf(c);"))
(define srcTR (session-focus-vid (ctx-session ctxTR0)))
(define src-did (editor-view-document-id (session-editor (ctx-session ctxTR0)) srcTR))
;; C-t 开译文文档
(define ctxTR1 (step ctxTR0 (key-event #\t (mods #t #f #f))))
(define sTR (ctx-session ctxTR1))
(define edTR (session-editor sTR))
(define mirror-vid (session-focus-vid sTR))
(define mirror-did (editor-view-document-id edTR mirror-vid))
(check-true (not (eqv? srcTR mirror-vid)) "C-t 新开译文视图")
(check-equal? (length (frame-leaves (session-frame sTR))) 1 "译文与原文件同在一个叶子")
(check-equal? (leaf-views (car (frame-leaves (session-frame sTR)))) (list srcTR mirror-vid)
              "叶子内固定左右布局")
(check-equal? (editor-document-string edTR mirror-did) "打印(a);\n显示(b);\n打印(c);"
              "开译文文档（正向）")
(check-equal? (editor-view-string edTR srcTR) "printf(a);\ndisplay(b);\nprintf(c);"
              "源文档不变")
;; 渲染：一个叶子内两块都上屏
(define-values (_trc trscr) (app-render ctxTR1))
(check-true (regexp-match? #rx"printf" (screen->string trscr)) "渲染：原文窗格")
(check-true (regexp-match? #rx"打印" (screen->string trscr)) "渲染：译文窗格")

;; 源编辑 → 译文同步
(define ctxTR2 (apply-effects! ctxTR1
                 (list (e-move srcTR (selections-one (caret (point 2 10))))
                       (e-type srcTR "\nprintf(d);" #f))))
(check-equal? (editor-document-string (session-editor (ctx-session ctxTR2)) mirror-did)
              "打印(a);\n显示(b);\n打印(c);\n打印(d);" "源编辑 → 译文同步")

;; 译文编辑 → 源同步（反向）
(define ctxTR3 (apply-effects! ctxTR2
                 (list (e-move mirror-vid (selections-one (caret (point 3 6))))
                       (e-type mirror-vid "\n显示(e);" #f))))
(check-equal? (editor-document-string (session-editor (ctx-session ctxTR3)) src-did)
              "printf(a);\ndisplay(b);\nprintf(c);\nprintf(d);\ndisplay(e);" "译文编辑 → 源同步")

;; 视口同步：先渲染一次让 anchor 快照对齐，再动源侧
(define ctxTR4 (run-notify ctxTR3 'before-render '()))
(editor-view-set-anchor! (session-editor (ctx-session ctxTR4)) srcTR 2 0)
(define ctxTR5 (run-notify ctxTR4 'before-render '()))
(check-equal? (editor-view-top-line (session-editor (ctx-session ctxTR5)) mirror-vid) 2
              "视口同步：源滚动 → 译文跟随")
;; 反向：动译文侧
(editor-view-set-anchor! (session-editor (ctx-session ctxTR5)) mirror-vid 0 0)
(define ctxTR6 (run-notify ctxTR5 'before-render '()))
(check-equal? (editor-view-top-line (session-editor (ctx-session ctxTR6)) srcTR) 0
              "视口同步：译文滚动 → 源跟随")

;; 关配对：走管线 e-close 关译文文档 → 帧叶同步移除 + 配对清理
(define trSvc (service-ref ctxTR6 'translate))
(check-equal? (length (tr-pairs trSvc)) 1 "登记一对")
(define ctxTR7 (apply-effects! ctxTR6 (list (e-close (list mirror-did)))))
(check-equal? (length (tr-pairs (service-ref ctxTR7 'translate))) 0 "关闭文档后清配对")
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxTR7)))) 1 "关闭文档后只剩一叶")

;; 再开一次，用 translate-close 关配对
(define ctxTR8 (apply-effects! ctxTR7 (list (fx 'translate-open))))
(check-equal? (length (leaf-views (car (frame-leaves (session-frame (ctx-session ctxTR8)))))) 2
              "重新开译文")
(define ctxTR9 (apply-effects! ctxTR8 (list (fx 'translate-close))))
(check-equal? (length (tr-pairs (service-ref ctxTR9 'translate))) 0 "translate-close 清配对")
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxTR9)))) 1 "translate-close 只剩一叶")

;;; ================= 两层布局：叶子内固定布局 =================
(require "kernel/frame.rkt")
(define (rrects fr a)
  (define-values (rs _bs) (frame->rectangles fr a))
  (for/list ([r (in-list rs)]) (list (rectangle-view-id r) (rectangle-x r) (rectangle-y r)
                                     (rectangle-width r) (rectangle-height r))))
;; 叶内 左右 均分：1 格 gap，两视图各占一块
(define fa (area 0 0 20 6))
(define f-inner (frame-new (leaf (isplit* 'lr 0 1) 'edit)))
(check-equal? (rrects f-inner fa) '((0 0 0 9 6) (1 10 0 10 6)) "叶内左右固定布局展开成两块")
(check-true (frame-contains? f-inner 0) "frame-contains? 认叶内视图")
(check-true (frame-contains? f-inner 1) "frame-contains? 认叶内视图（第二个）")
(check-false (frame-contains? f-inner 2) "frame-contains? 不认未放入视图")
(check-equal? (leaf-views (frame-find f-inner 1)) '(0 1) "frame-find 返回含该 view 的叶")
;; 叶内 上下
(define f-inner2 (frame-new (leaf (isplit* 'tb 0 1) 'edit)))
(check-equal? (rrects f-inner2 fa) '((0 0 0 20 2) (1 0 3 20 3)) "叶内上下固定布局展开成两块")
;; 删叶内一个视图：只摘掉它，叶还在
(define f-inner3 (frame-remove f-inner 0))
(check-equal? (length (frame-leaves f-inner3)) 1 "删叶内一个视图后叶还在")
(check-equal? (leaf-views (car (frame-leaves f-inner3))) '(1) "删叶内一个视图只摘掉它")
;; 叶内换 view / swap
(check-equal? (leaf-views (car (frame-leaves (frame-replace-view f-inner 0 2)))) '(2 1)
              "frame-replace-view 保叶内结构")
(check-equal? (leaf-views (car (frame-leaves (frame-swap f-inner 0 1)))) '(1 0)
              "frame-swap 叶内两视图互换位置")
;; group / ungroup
(define f-two (frame-new (split 'lr #f (leaf 0 'edit) (leaf 1 'edit))))
(define f-grp (frame-group f-two 0 1 'tb))
(check-equal? (length (frame-leaves f-grp)) 1 "group 后两叶合一叶")
(check-equal? (leaf-views (car (frame-leaves f-grp))) '(0 1) "group 保留内层布局")
(check-equal? (length (frame-leaves (frame-ungroup f-grp 0))) 2 "ungroup 还原成两叶")
;; 对含内层布局的叶做外层分屏：叶整体作为一侧，外层叶数 +1
(define f-split (frame-split f-grp 0 'lr 2))
(check-equal? (length (frame-leaves f-split)) 2 "可以在组合叶外再分屏")
(check-equal? (map leaf-views (frame-leaves f-split)) '((0 1) (2)) "外层分屏不动叶内布局")
;; 整叶交换：结构随内容一起走，不拆开组合叶
(check-equal? (map leaf-views (frame-leaves (frame-swap-leaf f-split 0 2))) '((2) (0 1))
              "frame-swap-leaf 整叶交换")
;; 整叶关闭：含内层布局的叶一次关掉
(check-equal? (map leaf-views (frame-leaves (frame-drop-leaf f-split 0))) '((2))
              "frame-drop-leaf 关整叶")
;; 叶级几何：一个叶子一块（整叶包围盒），不受叶内 view 影响
(define leaf-rects (frame->leaf-rects f-split fa))
(check-equal? (map (λ (e) (list (leaf-views (car e))
                                (rectangle-x (cdr e)) (rectangle-y (cdr e))
                                (rectangle-width (cdr e)) (rectangle-height (cdr e))))
                   leaf-rects)
              '(((0 1) 0 0 9 6) ((2) 10 0 10 6))
              "frame->leaf-rects 一个叶子一块")

;; e2e：pane-swap 以叶为单位（组合叶整体移动，不被拆开）
(define ctxGV0 (press-ctrl (type-all (fresh) "printf(a);") #\t))   ; translate → 一叶含两 view
(define ctxGV1 (press-ctrl ctxGV0 #\l))                             ; split-lr → 组合叶 | 新叶
(define gv-leaves1 (frame-leaves (session-frame (ctx-session ctxGV1))))
(check-equal? (map (λ (l) (length (leaf-views l))) gv-leaves1) '(2 1) "split 后组合叶在左")
(define gv-group-vid (car (leaf-views (car gv-leaves1))))
(define ctxGV2 (apply-effects! ctxGV1 (list (e-focus gv-group-vid))))
(define ctxGV3 (apply-effects! ctxGV2 (list (e-pane-swap 'right))))
(define gv-leaves2 (frame-leaves (session-frame (ctx-session ctxGV3))))
(check-equal? (map (λ (l) (length (leaf-views l))) gv-leaves2) '(1 2) "pane-swap 整叶移动不拆叶")
(check-equal? (map leaf-views gv-leaves2) (list (leaf-views (cadr gv-leaves1)) (leaf-views (car gv-leaves1)))
              "pane-swap 后组合叶完整地到了右侧")
(define ctxGV4 (apply-effects! ctxGV3 (list (e-focus (car (leaf-views (cadr gv-leaves2)))))))
(define ctxGV5 (apply-effects! ctxGV4 (list (e-pane-close))))
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxGV5)))) 1 "pane-close 关整叶")
(check-equal? (leaf-views (car (frame-leaves (session-frame (ctx-session ctxGV5)))))
              (leaf-views (cadr gv-leaves1)) "pane-close 关掉组合叶后只剩另一叶")

;; e-close 文档：组合叶里只摘该文档的 view，其它 view 保留；都关完叶才消失
(define ctxCL0 (press-ctrl (type-all (fresh) "printf(a);") #\t))
(define cl-s (ctx-session ctxCL0))
(define cl-ed (session-editor cl-s))
(define cl-vids (leaf-views (car (frame-leaves (session-frame cl-s)))))
(define cl-src-did (editor-view-document-id cl-ed (car cl-vids)))
(define cl-mir-did (editor-view-document-id cl-ed (cadr cl-vids)))
(define ctxCL1 (apply-effects! ctxCL0 (list (e-close (list cl-src-did)))))
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxCL1)))) 1 "关一个文档后叶还在")
(check-equal? (leaf-views (car (frame-leaves (session-frame (ctx-session ctxCL1))))) (list (cadr cl-vids))
              "组合叶只摘掉被关文档的 view")
(define ctxCL2 (apply-effects! ctxCL1 (list (e-close (list cl-mir-did)))))
(check-equal? (length (frame-leaves (session-frame (ctx-session ctxCL2)))) 0 "两个文档都关后叶消失")

(displayln "smoke: all passed")
