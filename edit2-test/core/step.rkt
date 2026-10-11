#lang racket

;;; edit2-test/step.rkt —— edit2/step.rkt 的外部测试（控制流 / 路由 / 资源 / 窗口）

(require rackunit
         racket/file
         racket/list
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

(define (focus-vid st) (wid-vid st (state-focus st)))
(define (focus-panel-name st) (wid-panel-name st (state-focus st)))
(define (editor-wid-vids st) (for/list ([w (in-list (editor-wids st))]) (wid-vid st w)))

;; 资源面板（唯一能新建 view 的地方）：焦点到侧栏缓冲区，建一个未显示 view。
(define (to-buffers st) (region-focus! (region-activate! st 'sidebar "*buffers*") 'sidebar))
(define (res-new-view st) (run1 (to-buffers st) (key-event 'n '())))
;; 分裂 = 新建窗口（同一个 view 可出现在多个窗口），用 C-w 即可。
(define (split-two st) (run1 st (key-event 'w '(ctrl))))

;; ---- 基本编辑 ----
(define st1 (run1 (fresh) (text-event "XY")))
(check-equal? (document-string (state-ed st1) (focused-did st1)) "XYabc")

;; 回归：*scratch* 是普通缓冲区，不是面板
(define ssc (boot "abc" "*scratch*" 60 16 #:root (current-directory)))
(check-false (focus-panel-name ssc))
(check-equal? (document-string (state-ed (run1 ssc (text-event "Z"))) (focused-did ssc)) "Zabc")

;; 启动不带文件（name = #f）→ 不建初始文档：空窗口，缓冲区无用户文档
(define snodoc (boot "" #f 60 16 #:root (current-directory)))
(check-false (focused-did snodoc))
(check-equal? (length (buffer-rows snodoc)) 0)
(check-true (regexp-match? #rx"空窗口"
                           (view-string (state-ed (refresh-panels! snodoc)) (panel-vid snodoc "*status*"))))
;; 无文档时编辑为 no-op（不崩）
(define snodoc2 (run1 snodoc (text-event "Z")))
(check-false (focused-did snodoc2))

;; 状态栏 / 资源面板显示相对文件树根的路径
(define rt (current-directory))
(define ssp (set-focused-path! (boot "abc" "t" 60 16 #:root rt)
                               (build-path rt "edit2" "step.rkt")))
(define ssp2 (refresh-panels! ssp))
(check-true (regexp-match? #rx"edit2[/\\\\]step\\.rkt"
                           (view-string (state-ed ssp2) (panel-vid ssp2 "*status*"))))
(check-true (regexp-match? #rx"edit2[/\\\\]step\\.rkt"
                           (view-string (state-ed ssp2) (panel-vid ssp2 "*buffers*"))))

(define st2 (run1 (run1 (fresh) (text-event "XY")) (key-event 'backspace '())))
(check-equal? (document-string (state-ed st2) (focused-did st2)) "Xabc")

;; ---- 分裂：新增**空窗口**（wid），不在新窗口显示原 view ----
(define st3 (run1 (fresh) (key-event 'w '(ctrl))))
(check-equal? (length (view-id-list (state-ed st3))) 6)      ; 不新建 view
(check-equal? (length (layout-wids (state-layout st3))) 4)   ; tree + status + editor×2 窗口
(check-equal? (length (editor-wids st3)) 2)
(check-equal? (length (filter (lambda (w) (wid-vid st3 w)) (editor-wids st3))) 1)       ; 1 个有 view
(check-equal? (length (filter (lambda (w) (not (wid-vid st3 w))) (editor-wids st3))) 1) ; 1 个空
(check-false (wid-vid st3 (state-focus st3)))                ; 焦点在空窗口
(check-true (regexp-match? #rx"空窗口"
                           (view-string (state-ed (refresh-panels! st3)) (panel-vid st3 "*status*"))))
;; 关空窗口
(define st3c (run1 st3 (key-event 'd '(ctrl))))
(check-equal? (length (editor-wids st3c)) 1)
(check-equal? (length (view-id-list (state-ed st3c))) 6)

;; ---- 同 view 多位置（core 支持）：手工把空窗口填成同一个 vid ----
(define st3-vid (wid-vid st3 (car (filter (lambda (w) (wid-vid st3 w)) (editor-wids st3)))))
(define st3v (struct-copy state st3
                          [layout (layout-set-pane-vid (state-layout st3) (state-focus st3) st3-vid)]))
(check-equal? (length (editor-wids st3v)) 2)
(check-equal? (length (remove-duplicates (editor-wid-vids st3v))) 1)   ; 两窗口同一 vid
;; 关一个窗口：另一个还在，view 不变
(define st3v2 (run1 st3v (key-event 'd '(ctrl))))
(check-equal? (length (editor-wids st3v2)) 1)
(check-equal? (length (view-id-list (state-ed st3v2))) 6)
;; 关闭 view 资源：显示它的所有窗口一起消失，保留一个空窗口
(define st3v3 (run1 (run1 (to-buffers st3v2) (key-event 'down '())) (key-event 'd '(ctrl))))
(check-equal? (length (view-id-list (state-ed st3v3))) 5)
(check-equal? (length (filter (lambda (w) (wid-vid st3v3 w)) (editor-wids st3v3))) 0)

;; 焦点切换
(define st4 (run1 (fresh) (key-event 't '(alt))))
(check-equal? (focus-panel-name st4) "*tree*")
(define st5 (run1 st4 (key-event 'e '(alt))))
(check-false (focus-panel-name st5))

;; 侧栏：tree / buffers 共享同一区域，C-b 整体显隐
(define stb (run1 (fresh) (key-event 'b '(alt))))
(check-equal? (region-visible-vid stb 'sidebar) (panel-vid stb "*buffers*"))
(define stb2 (run1 stb (key-event 'b '(ctrl))))
(check-false (region-visible? stb2 'sidebar))
(define stb3 (run1 stb2 (key-event 'b '(ctrl))))
(check-equal? (region-visible-vid stb3 'sidebar) (panel-vid stb3 "*buffers*"))
;; 面板键不会插进树文字
(define st6 (run1 (run1 (fresh) (key-event 't '(alt))) (text-event "x")))
(check-equal? (focus-panel-name st6) "*tree*")
;; 隐藏侧栏时，聚焦面板被撤 → 焦点回编辑器
(define stf (run1 (fresh) (key-event 't '(alt))))
(define stf2 (run1 stf (key-event 'b '(ctrl))))
(check-false (focus-panel-name stf2))

;; ---- 一切皆 document：面板选择 = 面板 doc 的光标行 ----
(define stt0 (fresh))
(check-equal? (view-line (state-ed stt0) (panel-vid stt0 "*tree*")) 0)
(define stt1 (run1 (run1 stt0 (key-event 't '(alt))) (key-event 'down '())))
(check-equal? (view-line (state-ed stt1) (panel-vid stt1 "*tree*")) 1)
(define stt2 (run1 (fresh) (cursor-event 'press 'left 2 3)))   ; 屏幕行 3 = 内容行 2（上方 1 行边框）
(check-equal? (view-line (state-ed stt2) (panel-vid stt2 "*tree*")) 2)
;; 指针：布局命中 → 定位光标（编辑器窗格从列 28 开始）
(define st0 (fresh))
(define ps (layout (state-layout st0) (cons 60 16)))
(define c (ctx (cons 60 16) ps))
(define stc (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 30 0)))
                              (lambda (s e) s)))
(check-false (focus-panel-name stc))
(check-equal? (view-col (state-ed stc) (focus-vid stc)) 2)
(define stc2 (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 2 0)))
                               (lambda (s e) s)))
(check-equal? (focus-panel-name stc2) "*tree*")

;; ---- 退出 ----
(define r (run-ev (fresh) (key-event 'q '(ctrl))))
(check-true (quit-effect? (car (cadr r))))
(define sq (run1 (run1 (fresh) (text-event "Z")) (key-event 'q '(ctrl))))
(check-true (prompt? (state-input sq)))
(define sq2 (run-ev (run1 sq (text-event "n")) (key-event 'enter '())))
(check-true (quit-effect? (car (cadr sq2))))

;; ---- 三级资源：窗口 ⊂ 视图 ⊂ 文档 ----
;; C-d 只摘窗口：view / document 资源都保留
(define sc (split-two (fresh)))
(check-equal? (length (editor-wids sc)) 2)
(define sc2 (run1 sc (key-event 'd '(ctrl))))
(check-equal? (length (view-id-list (state-ed sc2))) 6)   ; 视图资源不变
(check-equal? (length (editor-wids sc2)) 1)               ; 窗口少一个
(check-false (prompt? (state-input sc2)))

;; C-d 关脏窗口也不问保存（资源没丢，文本还在）
(define sd (run1 (fresh) (text-event "Z")))
(define sd-did (focused-did sd))
(define sd1 (run1 sd (key-event 'd '(ctrl))))
(check-false (prompt? (state-input sd1)))
(check-equal? (document-string (state-ed sd1) sd-did) "Zabc")

;; 关掉所有编辑窗口后，状态栏仍固定在底部（持久空位，不让 split 塌缩）
(define se (run1 (fresh) (key-event 'd '(ctrl))))
(define sv (panel-vid se "*status*"))
(define pse (layout (state-layout se) (cons 60 16)))
(define sp (for/first ([p (in-list pse)] #:when (eqv? (placement-vid p) sv)) p))
(check-equal? (rect-y (placement-rect sp)) 14)

;; 缓冲区面板 = 资源管理器。C-d 关选中视图资源：视图 -1，文档不变
(define sb0 (run1 (fresh) (key-event 'b '(alt))))
(check-equal? (focus-panel-name sb0) "*buffers*")
(define sb1 (run1 (run1 sb0 (key-event 'down '())) (key-event 'd '(ctrl))))
(check-equal? (length (view-id-list (state-ed sb1))) 5)
(check-equal? (length (document-id-list (state-ed sb1))) 6)
;; 孤儿文档仍留在资源列表（一行，vid=#f），回车可重建视图
(check-equal? (length (buffer-items sb1)) 1)
(check-false (cadr (car (buffer-items sb1))))
(define sb2 (run1 sb1 (key-event 'enter '())))
(check-equal? (length (view-id-list (state-ed sb2))) 6)
(check-false (focus-panel-name sb2))

;; Delete 关选中文档资源：文档 -1，与其视图全部 -1（core 连带）
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

;; ---- 一个 document 对应多个 view（view 只在资源面板创建） ----
(define sm0 (fresh))
(define sm-did (focused-did sm0))
(define sm1 (res-new-view sm0))                               ; 资源面板新建第二个 view
(check-equal? (length (document-view-list (state-ed sm1) sm-did)) 2)
(check-equal? (length (document-id-list (state-ed sm1))) 6)
(check-equal? (length (view-id-list (state-ed sm1))) 7)
;; 资源面板是树：document 是根，view 是子
(define sm-rows (buffer-rows (refresh-panels! sm1)))
(check-equal? (length (filter (lambda (x) (eq? (list-ref x 4) 'doc)) sm-rows)) 1)
(check-equal? (length (filter (lambda (x) (eq? (list-ref x 4) 'view)) sm-rows)) 2)
(check-false (regexp-match? #rx"\\[1/2\\]"
                            (view-string (state-ed (refresh-panels! sm1))
                                         (panel-vid sm1 "*buffers*"))))

;; 从缓冲区关一个视图资源：文档保留，另一个视图还在
(define sm3 (run1 (run1 (to-buffers sm1) (key-event 'down '())) (key-event 'd '(ctrl))))
(check-equal? (length (document-view-list (state-ed sm3) sm-did)) 1)
(check-equal? (length (document-id-list (state-ed sm3))) 6)

;; 折叠式：Left 收起只剩 document 行；Right 展开回子行
(define smb0 (run1 (to-buffers sm1) (key-event 'left '())))
(check-equal? (length (buffer-rows smb0)) 1)
(define smb1 (run1 smb0 (key-event 'right '())))
(check-equal? (length (buffer-rows smb1)) 3)

;; 关文档：它名下所有 view 一起消失
(define sm4 (run1 sm3 (key-event 'delete '())))
(check-equal? (length (document-id-list (state-ed sm4))) 5)

;; ---- 打开已打开的文件：按路径复用 document ----
(define tdir (make-temporary-file "edit2test~a" 'directory))
(define fpath (build-path tdir "hello.txt"))
(call-with-output-file fpath #:exists 'truncate (lambda (o) (display "hi" o)))
(define so0 (boot "" "*scratch*" 60 16 #:root tdir))
(define so1 (run1 (run1 (run1 so0 (key-event 't '(alt))) (key-event 'down '())) (key-event 'enter '())))
(check-equal? (length (document-id-list (state-ed so1))) 7)
(check-equal? (length (view-id-list (state-ed so1))) 7)
(define so2 (run1 (run1 (run1 so1 (key-event 't '(alt))) (key-event 'down '())) (key-event 'enter '())))
(check-equal? (length (document-id-list (state-ed so2))) 7)
(check-equal? (length (view-id-list (state-ed so2))) 7)

;; ---- 侧栏贴根占满左侧整高：状态栏在同一右侧区里全宽贴底 ----
(define sfl (fresh))
(define psfl (layout (state-layout sfl) (cons 60 16)))
(define tp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*tree*"))) p))
(define stp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*status*"))) p))
(check-equal? (rect-y (placement-rect tp)) 0)
(check-equal? (rect-h (placement-rect tp)) 16)     ; 占满左侧整高
(check-equal? (rect-x (placement-rect stp)) 28)    ; 状态栏在侧栏右侧
(check-equal? (rect-y (placement-rect stp)) 14)
(check-equal? (rect-h (placement-rect stp)) 2)
(check-equal? (rect-w (placement-rect stp)) 32)    ; 60 - 28

;; ---- 区域代数 ----
(define sr0 (fresh))
(define sr1 (run1 sr0 (key-event 'b '(alt))))
(check-equal? (region-active sr1 'sidebar) "*buffers*")
(define sr2 (run1 sr1 (key-event 'b '(alt))))
(check-equal? (region-active sr2 'sidebar) "*tree*")
(define sr3 (run1 sr2 (key-event 'b '(ctrl))))
(check-false (region-visible? sr3 'sidebar))
(check-equal? (region-active sr3 'sidebar) "*tree*")
(define sr4 (run1 sr3 (key-event 'b '(ctrl))))
(check-true (region-visible? sr4 'sidebar))
(define srt (run1 (run1 (fresh) (key-event 't '(alt))) (key-event 'tab '())))
(check-equal? (region-active srt 'sidebar) "*buffers*")

;; ---- 区域锚点：侧栏贴根占满左高；日志贴主区让开底部状态栏 ----
(define (placement-of st name)
  (define ps (layout (state-layout st) (cons 60 16)))
  (for/first ([p (in-list ps)] #:when (eqv? (placement-vid p) (panel-vid st name))) p))
(check-equal? (rect-h (placement-rect (placement-of (fresh) "*tree*"))) 16)   ; 占满左侧整高
(check-false (placement-of sr3 "*tree*"))                                     ; 隐藏 → 没有
(check-equal? (rect-h (placement-rect (placement-of sr4 "*tree*"))) 16)       ; 再显示仍占满
(define slog (run1 (fresh) (key-event 'l '(ctrl))))
(define plog (placement-of slog "*log*"))
(define pstat (placement-of slog "*status*"))
(check-equal? (rect-x (placement-rect plog)) 28)                               ; 在侧栏右侧主区里
(check-equal? (+ (rect-y (placement-rect plog)) (rect-h (placement-rect plog)))
              (rect-y (placement-rect pstat)))                                 ; 贴住状态栏上方

;; ---- 打开时多窗口 → 选择目标窗口（放置模式） ----
(define (open-hello st) (run1 (run1 (run1 st (key-event 't '(alt))) (key-event 'down '())) (key-event 'enter '())))

;; 造两个**非空**编辑窗口：分裂出空窗口，再把它填成同一个 vid（同 view 多位置）。
(define (boot-tdir) (boot "base" "*scratch*" 60 16 #:root tdir))
(define (two-nonempty st)
  (define s (run1 st (key-event 'w '(ctrl))))
  (define v (wid-vid s (car (filter (lambda (w) (wid-vid s w)) (editor-wids s)))))
  (struct-copy state s [layout (layout-set-pane-vid (state-layout s) (state-focus s) v)]))

(define spl1 (two-nonempty (boot-tdir)))
(check-equal? (length (editor-wids spl1)) 2)
(check-equal? (length (filter (lambda (w) (wid-vid spl1 w)) (editor-wids spl1))) 2)   ; 无空窗口
(define spl2 (open-hello spl1))
(check-true (placing? (feature-ref spl2 'placing #f)))
(check-equal? (length (editor-wids spl2)) 2)               ; 布局未动
(check-true (regexp-match? #rx"选择目标"
                           (view-string (state-ed (refresh-panels! spl2))
                                        (panel-vid spl2 "*status*"))))
;; Tab 切换目标窗口 → Enter 替换（改该窗口的 vid，不新建 view/wid）
(define spl3 (run1 spl2 (key-event 'tab '())))
(define spl4 (run1 spl3 (key-event 'enter '())))
(check-false (placing? (feature-ref spl4 'placing #f)))
(check-equal? (length (editor-wids spl4)) 2)
(check-equal? (length (remove-duplicates (editor-wid-vids spl4))) 2)  ; 两窗口两个不同 doc
(check-equal? (document-string (state-ed spl4) (view-did (state-ed spl4) (focus-vid spl4))) "hi")

;; Esc 取消：布局与焦点恢复，待放视图资源保留
(define splc (two-nonempty (boot-tdir)))
(define spl5 (open-hello splc))
(define spl6 (run1 spl5 (key-event 'escape '())))
(check-false (placing? (feature-ref spl6 'placing #f)))
(check-equal? (editor-wids spl6) (editor-wids splc))
(check-equal? (focus-panel-name spl6) "*tree*")
(check-true (> (length (document-id-list (state-ed spl6))) 6))

;; 放置模式下按无关键 → 退出放置（瞬时模式语义）
(define spl7 (open-hello (two-nonempty (boot-tdir))))
(check-true (placing? (feature-ref spl7 'placing #f)))
(define spl8 (run1 spl7 (key-event 'b '(ctrl))))
(check-false (placing? (feature-ref spl8 'placing #f)))

;; ---- 文件树行为：顶部根目录、隐藏项、Enter/光标、C-n 新建、C-d 删除、C-u 刷新 ----
(define (make-tdir) (make-temporary-file "edit2tree~a" 'directory))
(define (tree-focus st) (run1 st (key-event 't '(alt))))
(define (tree-names st)   ; 丢掉顶部根目录行
  (define st* (refresh-panels! st))
  (define rows (tree-rows (tree-ensure (feature-ref st* 'tree #f))))
  (map (lambda (x) (list-ref x 1)) (cdr rows)))

;; 顶部第一行是工作区根目录；默认隐藏 . 开头的条目，C-h 切换
(define dhid (make-tdir))
(make-directory (build-path dhid ".git"))
(call-with-output-file (build-path dhid "normal.txt") #:exists 'truncate (lambda (o) (display "N" o)))
(define th1 (tree-focus (boot "" "x" 60 16 #:root dhid)))
(define th1-rows (tree-rows (tree-ensure (feature-ref (refresh-panels! th1) 'tree #f))))
(check-equal? (car (car th1-rows)) (simplify-path (path->complete-path dhid)))   ; 顶部 = 根
(check-equal? (tree-names th1) '("normal.txt"))                                ; .git 隐藏
(define th2 (run1 th1 (key-event 'h '(ctrl))))
(check-not-false (member ".git" (tree-names th2)))                             ; C-h 显示
(define th3 (run1 th2 (key-event 'h '(ctrl))))
(check-equal? (tree-names th3) '("normal.txt"))                                ; C-h 再隐藏

;; 导航：Enter 展开 sub，←→ 光标横移
(define dnav (make-tdir))
(make-directory (build-path dnav "sub"))
(call-with-output-file (build-path dnav "sub" "a.txt") #:exists 'truncate (lambda (o) (display "A" o)))
(define tn1 (tree-focus (boot "" "x" 60 16 #:root dnav)))
(check-equal? (tree-names tn1) '("sub"))
(define tn1b (run1 tn1 (key-event 'down '())))          ; 光标到 sub
(define tn2 (run1 tn1b (key-event 'enter '())))         ; 展开
(check-equal? (tree-names tn2) '("sub" "a.txt"))
(define tn3 (run1 tn2 (key-event 'right '())))
(check-equal? (view-col (state-ed tn3) (panel-vid tn3 "*tree*")) 1)
(define tn4 (run1 tn3 (key-event 'left '())))
(check-equal? (view-col (state-ed tn4) (panel-vid tn4 "*tree*")) 0)

;; C-n f 新文件（目标 = 根目录行）
(define dnew (make-tdir))
(define tf1 (tree-focus (boot "" "x" 60 16 #:root dnew)))
(define tf2 (run1 tf1 (key-event 'n '(ctrl))))
(check-equal? (state-input tf2) 'new)
(define tf3 (run1 tf2 (key-event 'f '())))
(check-true (prompt? (state-input tf3)))
(define tf4 (run1 (run1 tf3 (text-event "new.txt")) (key-event 'enter '())))
(check-true (file-exists? (build-path dnew "new.txt")))
(check-not-false (member "new.txt" (tree-names tf4)))
;; C-n C-n f 新目录
(define tf5 (run1 (run1 tf1 (key-event 'n '(ctrl))) (key-event 'n '(ctrl))))
(check-equal? (state-input tf5) 'new2)
(define tf6 (run1 (run1 (run1 tf5 (key-event 'f '())) (text-event "sub2")) (key-event 'enter '())))
(check-true (directory-exists? (build-path dnew "sub2")))

;; C-u 重读磁盘（外部新建），已打开文档不受影响
(define dref (make-tdir))
(define tu1 (refresh-panels! (boot "" "*scratch*" 60 16 #:root dref)))
(check-equal? (tree-names tu1) '())
(call-with-output-file (build-path dref "external.txt") #:exists 'truncate (lambda (o) (display "E" o)))
(define tu2 (run1 tu1 (key-event 'u '(ctrl))))
(check-not-false (member "external.txt" (tree-names tu2)))

;; C-d 删除（需确认）：光标走到 sub/a.txt
(define ddel (make-tdir))
(make-directory (build-path ddel "sub"))
(call-with-output-file (build-path ddel "sub" "a.txt") #:exists 'truncate (lambda (o) (display "A" o)))
(define td1 (run1 (run1 (run1 (tree-focus (boot "" "x" 60 16 #:root ddel))
                             (key-event 'down '())) (key-event 'enter '()))
                  (key-event 'down '())))
(define td2 (run1 td1 (key-event 'd '(ctrl))))
(check-true (prompt? (state-input td2)))
(define td3 (run1 (run1 td2 (text-event "y")) (key-event 'enter '())))
(check-false (file-exists? (build-path ddel "sub" "a.txt")))

;; 已打开的文件染 tree-open；文件夹始终 tree-dir（不看「打开」）
(define dto (make-tdir))
(call-with-output-file (build-path dto "a.txt") #:exists 'truncate (lambda (o) (display "A" o)))
(call-with-output-file (build-path dto "b.txt") #:exists 'truncate (lambda (o) (display "B" o)))
(define to1 (tree-focus (boot "" "x" 60 16 #:root dto)))
(define to1b (run1 to1 (key-event 'down '())))                    ; 光标到 a.txt
(define to2 (run1 to1b (key-event 'enter '())))                   ; 打开 a.txt
(define to3 (run1 (run1 to2 (key-event 't '(alt))) (key-event 'down '())))  ; 光标到 b.txt
(define-values (_tto tfaces) (tree-content (refresh-panels! to3) (panel-vid to3 "*tree*")))
(check-not-false (member 'tree-open (map cdr tfaces)))
(check-not-false (member 'tree-file (map cdr tfaces)))

;; 无初始文档启动 → 从文件树打开文件：就地填空窗口显示
(define dnd (make-tdir))
(call-with-output-file (build-path dnd "n.txt") #:exists 'truncate (lambda (o) (display "N" o)))
(define tnd0 (boot "" #f 60 16 #:root dnd))
(check-false (focused-did tnd0))
(define tnd1 (run1 (run1 (tree-focus tnd0) (key-event 'down '())) (key-event 'enter '())))
(check-equal? (document-string (state-ed tnd1) (focused-did tnd1)) "N")
(check-equal? (length (buffer-rows tnd1)) 2)   ; 1 document + 1 view（资源树两行）

(displayln "edit2/step.rkt: all tests passed")
