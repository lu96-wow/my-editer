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
(check-equal? (length (session-panels (ctx-session ctx0))) 1 "有 buffers 面板")
(check-false (session-sidebar? (ctx-session ctx0)) "侧栏默认隐藏")
(define ctxPan1 (press-ctrl ctx0 #\b))
(check-true (session-sidebar? (ctx-session ctxPan1)) "侧栏显示")
(check-equal? (session-focus-vid (ctx-session ctxPan1))
              (panel-vid (car (session-panels (ctx-session ctxPan1)))) "焦点到面板")
(define-values (_c1 scr) (app-render ctxPan1))
(check-true (regexp-match? #rx"scratch" (screen->string scr)) "侧栏渲染文档列表")
(define ctxPan2 (press-ctrl ctxPan1 #\b))
(check-false (session-sidebar? (ctx-session ctxPan2)) "侧栏隐藏")
(check-equal? (session-focus-vid (ctx-session ctxPan2)) vid "隐藏后焦点还原")

;;; ================= 鼠标（同一 resolve） =================
(check-equal? (rectangle-view-id (hit-pane ctx0 3 0)) vid "鼠标命中主视图")
(check-equal? (rectangle-view-id (hit-pane ctxPan1 3 0))
              (panel-vid (car (session-panels (ctx-session ctxPan1)))) "鼠标命中面板")
(define ctxM (step (press (step (press ctx0 #\a) (key-event 'enter no-mods)) #\b)
                   (mouse-event 5 2 'press 'left no-mods)))
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
(define ctxI2 (step ctxI (key-event 'enter no-mods)))
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

;;; ================= 补全（deco 浮层 + layer） =================
(define ctxC0 (press (press (press (fresh) #\d) #\e) #\f))
(define ctxC1 (step ctxC0 (key-event #\n (mods #t #f #f))))   ; C-n
(check-equal? (length (input-instances (session-input (ctx-session ctxC1)))) 1 "C-n 弹补全")
(define-values (_cc scrC) (app-render ctxC1))
(check-true (regexp-match? #rx"define" (screen->string scrC)) "菜单显示候选")
(define ctxC2 (step ctxC1 (key-event 'tab no-mods)))          ; accept
(check-true (string-prefix? (view-string ctxC2) "def") "接受候选（前缀保留）")
(check-true (> (string-length (view-string ctxC2)) 3) "接受候选（变长）")
(check-equal? (input-instances (session-input (ctx-session ctxC2))) '() "接受后出栈")

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

(displayln "smoke: all passed")
