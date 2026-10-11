#lang racket

;;; edit2-test/step.rkt —— edit2/step.rkt 的外部测试（控制流 / 路由 / 关闭）

(require rackunit
         racket/file
         "../../edit2/core/step.rkt"
         "../../edit2/core/event.rkt"
         "../../edit2/core/effect.rkt"
         "../../edit2/core/route.rkt"
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/adapter.rkt"
         "../../edit2/core/panels.rkt")

(define routes (app-routes))
(define (fresh) (boot "abc" "t" 60 16 #:root (current-directory)))
(define (ctx-of st)
  (define ps (layout (state-layout st) (cons 60 16)))
  (set-layout! (state-ed st) ps)   ; 模拟渲染：把尺寸落到 view（否则面板视口高=1）
  (ctx (cons 60 16) ps))
(define (run1 st ev)
  (define st* (refresh-panels! st))   ; 模拟运行时每帧先刷面板
  (call-with-values (lambda () (step routes (ctx-of st*) st* ev)) (lambda (s e) s)))
(define (run-ev st ev)
  (call-with-values (lambda () (step routes (ctx-of st) st ev)) list))

;; 输入文本 → core 里变了（每个用例从 fresh 起：core 编辑原地 mutate）
(define st1 (run1 (fresh) (text-event "XY")))
(check-equal? (document-string (state-ed st1) (focused-did st1)) "XYabc")

;; 回归：*scratch* 是普通缓冲区，不是面板（否则按键与点击定位都被守卫/面板分支吞掉）
(define ssc (boot "abc" "*scratch*" 60 16 #:root (current-directory)))
(check-false (panel-name ssc (state-focus ssc)))
(check-equal? (document-string (state-ed (run1 ssc (text-event "Z"))) (focused-did ssc)) "Zabc")

;; 状态栏显示相对文件树根的路径
(define rt (current-directory))
(define ssp (set-focused-path! (boot "abc" "t" 60 16 #:root rt)
                               (build-path rt "edit2" "step.rkt")))
(define ssp2 (refresh-panels! ssp))
(check-true (regexp-match? #rx"edit2[/\\\\]step\\.rkt"
                           (view-string (state-ed ssp2) (panel-vid ssp2 "*status*"))))
;; 资源视图（缓冲区面板）也显示相对文件树根的路径
(check-true (regexp-match? #rx"edit2[/\\\\]step\\.rkt"
                           (view-string (state-ed ssp2) (panel-vid ssp2 "*buffers*"))))

;; backspace
(define st2 (run1 (run1 (fresh) (text-event "XY")) (key-event 'backspace '())))
(check-equal? (document-string (state-ed st2) (focused-did st2)) "Xabc")

;; 分屏
(define st3 (run1 (fresh) (key-event 'w '(ctrl))))
(check-equal? (length (view-id-list (state-ed st3))) 7)   ; 1 编辑 + 5 面板，分屏后 +1
;; 焦点切换
(define st4 (run1 (fresh) (key-event 't '(alt))))
(check-equal? (panel-name st4 (state-focus st4)) "*tree*")
(define st5 (run1 st4 (key-event 'e '(alt))))
(check-false (panel-name st5 (state-focus st5)))
;; 侧栏：tree / buffers 共享同一区域，C-b 整体显隐
(define stb (run1 (fresh) (key-event 'b '(alt))))     ; M-b：侧栏切到缓冲区
(check-equal? (region-visible-vid stb 'sidebar) (panel-vid stb "*buffers*"))
(define stb2 (run1 stb (key-event 'b '(ctrl))))       ; C-b：隐藏侧栏
(check-false (region-visible? stb2 'sidebar))
(define stb3 (run1 stb2 (key-event 'b '(ctrl))))      ; 再 C-b：显示回上次成员（缓冲区）
(check-equal? (region-visible-vid stb3 'sidebar) (panel-vid stb3 "*buffers*"))
;; 面板键不会插进树文字
(define st6 (run1 (run1 (fresh) (key-event 't '(alt))) (text-event "x")))
(check-equal? (panel-name st6 (state-focus st6)) "*tree*")
;; 隐藏侧栏时，聚焦面板被撤 → 焦点回编辑器
(define stf (run1 (fresh) (key-event 't '(alt))))
(define stf2 (run1 stf (key-event 'b '(ctrl))))
(check-false (panel-name stf2 (state-focus stf2)))

;; 一切皆 document：树的选择 = 面板 doc 的光标行；点击/导航都走 document
(define stt0 (fresh))
(define tv (panel-vid stt0 "*tree*"))
(check-equal? (view-line (state-ed stt0) tv) 0)
(define stt1 (run1 (run1 stt0 (key-event 't '(alt))) (key-event 'down '())))
(check-equal? (view-line (state-ed stt1) (panel-vid stt1 "*tree*")) 1)
;; 点击树第 3 行 → 面板 doc 光标落到第 3 行（同一套屏幕→document 定位）
(define stt2 (run1 (fresh) (cursor-event 'press 'left 2 2)))
(check-equal? (view-line (state-ed stt2) (panel-vid stt2 "*tree*")) 2)
;; 指针事件：布局命中 → 定位光标（编辑器窗格从列 28 开始）
(define st0 (fresh))
(define ps (layout (state-layout st0) (cons 60 16)))
(define c (ctx (cons 60 16) ps))
(define stc (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 30 0)))
                              (lambda (s e) s)))
(check-false (panel-name stc (state-focus stc)))
(check-equal? (view-col (state-ed stc) (state-focus stc)) 2)
;; 点在树面板上 → 聚焦树，编辑器不动
(define stc2 (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 2 0)))
                               (lambda (s e) s)))
(check-equal? (panel-name stc2 (state-focus stc2)) "*tree*")

;; 退出：干净 → 直接 quit-effect
(define r (run-ev (fresh) (key-event 'q '(ctrl))))
(check-true (quit-effect? (car (cadr r))))

;; 退出：脏 → 弹 prompt（不是立刻退）
(define sq (run1 (run1 (fresh) (text-event "Z")) (key-event 'q '(ctrl))))
(check-true (prompt? (state-input sq)))
;; 答 n → 退出
(define sq2 (run-ev (run1 sq (text-event "n")) (key-event 'enter '())))
(check-true (quit-effect? (car (cadr sq2))))

;; ---- 资源管理：窗口 ⊂ 视图 ⊂ 文档 ----
;; C-d 只摘窗口（pane）：view / document 资源都保留。
(define sc (run1 (fresh) (key-event 'w '(ctrl))))          ; 分屏 → 7 视图
(define sc2 (run1 sc (key-event 'd '(ctrl))))              ; C-d 关窗口
(check-equal? (length (view-id-list (state-ed sc2))) 7)    ; 视图资源不变
(check-equal? (length (layout-vids (state-layout sc2)))    ; 布局少一个 pane
              (sub1 (length (layout-vids (state-layout sc)))))
(check-false (prompt? (state-input sc2)))

;; C-d 关脏窗口也不问保存（资源没丢，文本还在）。
(define sd (run1 (fresh) (text-event "Z")))
(define sd-did (focused-did sd))
(define sd1 (run1 sd (key-event 'd '(ctrl))))
(check-false (prompt? (state-input sd1)))
(check-equal? (document-string (state-ed sd1) sd-did) "Zabc")

;; 关掉所有编辑窗口后，状态栏仍固定在底部（编辑区留持久空位，不让 split 塌缩）
(define se (run1 (fresh) (key-event 'd '(ctrl))))
(define sv (panel-vid se "*status*"))
(define pse (layout (state-layout se) (cons 60 16)))
(define sp (for/first ([p (in-list pse)] #:when (eqv? (placement-vid p) sv)) p))
(check-equal? (rect-y (placement-rect sp)) 15)

;; 缓冲区面板 = 资源管理器。C-d 关选中视图资源：视图 -1，文档不变。
(define sb0 (run1 (fresh) (key-event 'b '(alt))))          ; 侧栏切到缓冲区并聚焦
(check-equal? (panel-name sb0 (state-focus sb0)) "*buffers*")
(define sb1 (run1 sb0 (key-event 'd '(ctrl))))
(check-equal? (length (view-id-list (state-ed sb1))) 5)    ; 6 → 5
(check-equal? (length (document-id-list (state-ed sb1))) 6) ; 文档不变
;; 孤儿文档仍留在资源列表（一行，vid=#f），回车可重建视图
(check-equal? (length (buffer-items sb1)) 1)
(check-false (cadr (car (buffer-items sb1))))
(define sb2 (run1 sb1 (key-event 'enter '())))
(check-equal? (length (view-id-list (state-ed sb2))) 6)
(check-false (panel-name sb2 (state-focus sb2)))           ; 显示的是编辑视图

;; Delete 关选中文档资源：文档 -1，与其视图全部 -1（core 连带）。
(define sb3 (run1 (run1 (fresh) (key-event 'b '(alt))) (key-event 'delete '())))
(check-equal? (length (document-id-list (state-ed sb3))) 5)
(check-equal? (length (view-id-list (state-ed sb3))) 5)

;; 脏文档从缓冲区关闭 → 弹保存 prompt；答 n → 文档关掉
(define sb4 (run1 (run1 (fresh) (text-event "Z")) (key-event 'b '(alt))))
(define sb5 (run1 sb4 (key-event 'delete '())))
(check-true (prompt? (state-input sb5)))
(define sb6 (run1 (run1 sb5 (text-event "n")) (key-event 'enter '())))
(check-false (prompt? (state-input sb6)))
(check-equal? (length (document-id-list (state-ed sb6))) 5)

;; ---- 一个 document 对应多个 view ----
;; 分屏 = 同一 document 的第二个 view；文档数不变。
(define sm0 (fresh))
(define sm-did (focused-did sm0))
(define sm1 (run1 sm0 (key-event 'w '(ctrl))))
(check-equal? (length (document-view-list (state-ed sm1) sm-did)) 2)
(check-equal? (length (document-id-list (state-ed sm1))) 6)
;; 缓冲区面板逐视图列行，多视图标 [k/n]
(check-true (regexp-match? #rx"\\[1/2\\]"
                           (view-string (state-ed (refresh-panels! sm1))
                                        (panel-vid sm1 "*buffers*"))))

;; 关窗口只摘 pane：同一 document 的两个 view 都保留。
(define sm2 (run1 sm1 (key-event 'd '(ctrl))))
(check-equal? (length (document-view-list (state-ed sm2) sm-did)) 2)
(check-equal? (length (document-id-list (state-ed sm2))) 6)

;; 从缓冲区关一个视图资源：文档保留，另一个视图还在。
(define sm3 (run1 (run1 sm2 (key-event 'b '(alt))) (key-event 'd '(ctrl))))
(check-equal? (length (document-view-list (state-ed sm3) sm-did)) 1)
(check-equal? (length (document-id-list (state-ed sm3))) 6)

;; 关文档：它名下所有 view 一起消失。
(define sm4 (run1 sm3 (key-event 'delete '())))
(check-equal? (length (document-id-list (state-ed sm4))) 5)

;; 打开已打开的文件：按路径复用 document（不新建文档 / 视图）。
(define tdir (make-temporary-file "edit2test~a" 'directory))
(define fpath (build-path tdir "hello.txt"))
(call-with-output-file fpath #:exists 'truncate (lambda (o) (display "hi" o)))
(define so0 (boot "" "*scratch*" 60 16 #:root tdir))
(define so1 (run1 (run1 so0 (key-event 't '(alt))) (key-event 'enter '())))  ; 树第 0 行 = hello.txt
(check-equal? (length (document-id-list (state-ed so1))) 7)   ; 6 + 1
(check-equal? (length (view-id-list (state-ed so1))) 7)
(define so2 (run1 (run1 so1 (key-event 't '(alt))) (key-event 'enter '())))
(check-equal? (length (document-id-list (state-ed so2))) 7)   ; 文档不增
(check-equal? (length (view-id-list (state-ed so2))) 7)       ; 视图不增（复用已有）

;; 文件树贴顶：树从第 0 行、高=屏高-状态栏；状态栏全宽贴底
(define sfl (fresh))
(define psfl (layout (state-layout sfl) (cons 60 16)))
(define tp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*tree*"))) p))
(define stp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*status*"))) p))
(check-equal? (rect-y (placement-rect tp)) 0)
(check-equal? (rect-h (placement-rect tp)) 15)
(check-equal? (rect-y (placement-rect stp)) 15)
(check-equal? (rect-w (placement-rect stp)) 60)

;; 区域代数：成员循环 / 显隐 / 区域作用域（加成员不用加键）
(define sr0 (fresh))
(define sr1 (run1 sr0 (key-event 'b '(alt))))          ; cycle tree→buffers
(check-equal? (region-active sr1 'sidebar) "*buffers*")
(define sr2 (run1 sr1 (key-event 'b '(alt))))          ; cycle buffers→tree
(check-equal? (region-active sr2 'sidebar) "*tree*")
(define sr3 (run1 sr2 (key-event 'b '(ctrl))))         ; toggle 隐藏
(check-false (region-visible? sr3 'sidebar))
(check-equal? (region-active sr3 'sidebar) "*tree*")  ; 隐藏不改 active
(define sr4 (run1 sr3 (key-event 'b '(ctrl))))         ; toggle 显示回来
(check-true (region-visible? sr4 'sidebar))
;; 区域作用域：焦点在侧栏内时 Tab 切换成员
(define srt (run1 (run1 (fresh) (key-event 't '(alt))) (key-event 'tab '())))
(check-equal? (region-active srt 'sidebar) "*buffers*")

;; ---- 打开时多窗口 → 选择目标窗格（放置模式） ----
(define (ed-vids st)
  (for/list ([v (in-list (layout-vids (state-layout st)))]
             #:when (not (panel-name st v)))
    v))
(define (open-hello st) (run1 (run1 st (key-event 't '(alt))) (key-event 'enter '())))

;; 2 个编辑窗格时打开文件：不直接替换，而是进入放置模式等用户选。
(define spl1 (run1 (boot "base" "*scratch*" 60 16 #:root tdir) (key-event 'w '(ctrl))))
(check-equal? (length (ed-vids spl1)) 2)
(define spl2 (open-hello spl1))
(check-true (placing? (feature-ref spl2 'placing #f)))
(check-equal? (length (ed-vids spl2)) 2)               ; 布局未动
(check-true (regexp-match? #rx"选择目标"
                           (view-string (state-ed (refresh-panels! spl2))
                                        (panel-vid spl2 "*status*"))))
;; Tab 切换目标窗格 → Enter 替换
(define spl3 (run1 spl2 (key-event 'tab '())))
(define spl4 (run1 spl3 (key-event 'enter '())))
(check-false (placing? (feature-ref spl4 'placing #f)))
(check-equal? (length (ed-vids spl4)) 2)
(check-equal? (length (filter (lambda (v) (memv v (ed-vids spl4))) (ed-vids spl1))) 1)  ; 只替了 1 个
(check-equal? (document-string (state-ed spl4) (view-did (state-ed spl4) (state-focus spl4))) "hi")

;; Esc 取消：布局与焦点恢复，待放视图资源保留（可在缓冲区再显示）
(define splc (run1 (boot "base" "*scratch*" 60 16 #:root tdir) (key-event 'w '(ctrl))))
(define spl5 (open-hello splc))
(define spl6 (run1 spl5 (key-event 'escape '())))
(check-false (placing? (feature-ref spl6 'placing #f)))
(check-equal? (ed-vids spl6) (ed-vids splc))           ; 布局不变
(check-equal? (state-focus spl6) (panel-vid spl6 "*tree*"))  ; 焦点回进入前
(check-true (> (length (document-id-list (state-ed spl6))) 6))  ; 新文档还在

;; 放置模式下按无关键 → 退出放置（瞬时模式语义）
(define spl7 (open-hello (run1 (boot "base" "*scratch*" 60 16 #:root tdir) (key-event 'w '(ctrl)))))
(check-true (placing? (feature-ref spl7 'placing #f)))
(define spl8 (run1 spl7 (key-event 'b '(ctrl))))        ; C-b 切侧栏（无关命令）
(check-false (placing? (feature-ref spl8 'placing #f)))

(displayln "edit2/step.rkt: all tests passed")
