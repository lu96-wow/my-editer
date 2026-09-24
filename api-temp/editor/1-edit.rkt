#lang racket

;;; api-temp/editor/1-edit.rkt —— 最终 API · 编辑（core/editor.rkt）
;;;
;;; 这里只讲**平台面** `editor-*`：把底层（point / edit-desc / buffer / document / window）拼成
;;; 「可编辑的编辑器」。底层原理在 api-temp/api/，本文件是应用真正会用的那一层。
;;;
;;; ---------------------------------------------------------------------------
;;; editor 的数据模型（先读这段，后面的 id / count / focus 才不糊涂）
;;; ---------------------------------------------------------------------------
;;;
;;;   editor = documents（打开文档，稳定顺序）
;;;          ⊕ views（视口，稳定顺序）
;;;          ⊕ focus（当前焦点 vid）
;;;          ⊕ next-document / next-view（发号器）
;;;
;;;   document-entry = id ⊕ name ⊕ document ⊕ history ⊕ record?
;;;   view           = id ⊕ window ⊕ sync ⊕ link
;;;
;;; 为什么 document 和 view 分开？
;;;   document = 文本 + 属性（可编辑根，唯一状态源）；
;;;   view     = 选区 / 滚动 / 尺寸 / 模式（「怎么看」）。
;;;   同一个 document 可以开多个 view（分屏），各有独立光标 ——
;;;   所以「文档」和「视图」是两个独立生命周期，各有各的 id。
;;;
;;; 为什么用 id（而不是 list 下标）？
;;;   · id 是**稳定句柄**：单调递增、关闭后不复用；list 下标会因关闭而挪位，不能长期持有。
;;;   · 命令按 id 定位：`editor-view-*` 收 **vid**（作用到具体视口），
;;;     程序面 `editor-document-*` 收 **did**（作用到文档，不问焦点）。
;;;   · did = document id：管「哪个文档」（文本 / 属性 / 账本 / 历史策略）。
;;;   · vid = view id：管「哪个视口」（光标 / 选区 / 滚动 / 尺寸）。
;;;   · `editor-open` 产出的首个文档 did=0、首个 view vid=0。
;;;
;;; 为什么有 count？
;;;   · `editor-document-count` = 打开了几个文档（≈ buffer 数）；
;;;   · `editor-view-count`     = 有几个视口（≈ 屏幕窗格数；分屏时 > 文档数）。
;;;
;;; focus：
;;;   `editor-focus` 是 **vid**（不是 did）。`editor-point` / `editor-edit` 这类「焦点糖」
;;;   都作用于它；要精确作用到某个视口就用收 vid 的 `editor-view-*`。
;;;
;;; ---------------------------------------------------------------------------
;;; editor 层的两个形状约定
;;; ---------------------------------------------------------------------------
;;;   · 命令大多返回 (values editor report) —— 用 define-values / let-values 接；
;;;   · 编辑 op 是 **editor op**：editor did selection → edit-desc（edit-insert / edit-backspace / …）。
;;;     （buffer op 是另一层，喂 document-edit-at，见 api/1-edit.rkt。）
;;;
;;; 运行：racket api-temp/editor/1-edit.rkt

(require "../../core/editor.rkt"   ; 平台面（本文件的主角）
         "../../core/api.rkt")     ; 低层值：point / edit-desc / caret / read-only-key …（editor.rkt 不重导出）

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))

;;; ===========================================================================
(header "1. 构造 / 生命周期（id 从这里产生）")
;;; ===========================================================================

;; editor-open : string [nat nat] #:name #:history? #:line-numbers? → editor
;;   设计：唯一的「整编辑器」构造入口。内部建 document(0) 与它的第一个 view(0)，focus=0。
;;         #:history? 定这个文档的默认账本策略；#:line-numbers? 是视图装饰。
;;   用法：应用状态通常只存这一个 editor 值；后续开文档/开视口走下面两个。
(define e0 (editor-open "hello\nworld" 5 20 #:name "a.txt"))

;; editor-document-count : editor → nat
;;   设计：回答「打开了几个文档」（≈ buffer 数）。与 view-count 分开，因为一个文档可多视口。
;;   用法：buffer 列表长度、左右分屏时判断文档数。
(show "(editor-document-count e0)" (editor-document-count e0))
;; editor-view-count : editor → nat
;;   设计：回答「屏幕上有几个视口」（分屏时 > 文档数）。关闭 view 只减这个。
;;   用法：分屏管理、渲染前确认有 view。
(show "(editor-view-count e0)" (editor-view-count e0))
;; editor-document-id : editor → did（**焦点文档**的 id）
;;   设计：焦点糖。焦点 view → 它看的文档的 did。
;;   用法：不知道 did 时拿「当前文档」；要显式文档就用 editor-view-document-id。
(show "(editor-document-id e0)" (editor-document-id e0))
;; editor-focus : editor → (or/c vid #f)
;;   设计：焦点是 **vid**；「当前在哪个视口」。所有焦点糖都解析它。
;;   用法：判断左右窗格、切换焦点前先读它。
(show "(editor-focus e0)" (editor-focus e0))

;; editor-open-document : editor string [nat nat] #:name #:focus? #:history? #:line-numbers? → (values editor did)
;;   设计：新开一个**文档**并自动配一个 view。did 由 next-document 发号，永不复用。
;;         #:focus? 默认 #f（不抢焦点）——派生 UI（树/状态栏）在后台开文档时不打扰用户。
;;   用法：应用「开文件」用它；拿到 did 后可换 view 显示、可关。
(define-values (e1 did1) (editor-open-document e0 "BBB" 4 10 #:name "b.txt" #:focus? #f))
(show "新文档 did" did1)
(show "(editor-document-count e1)" (editor-document-count e1))
(show "(editor-document->string e1 did1)" (editor-document->string e1 did1))

;; editor-add-view : editor did [nat nat] [point] #:sync #:focus? #:link #:line-numbers? → (values editor vid)
;;   设计：给**已有文档**再加一个视口（分屏/同文本多光标）。vid 由 next-view 发号。
;;         #:sync 'free|'follow 是同文档镜像策略；#:link 是跨文档视口同步组名。
;;   用法：左右分屏、预览同文档；#:focus? #f 时不抢焦点。
(define-values (e2 vid2) (editor-add-view e1 0 3 8 #:focus? #f))
(show "新 view vid" vid2)
(show "(editor-view-count e2)" (editor-view-count e2))
(show "(editor-view-document-id e2 vid2)" (editor-view-document-id e2 vid2))

;; editor-focus-view / editor-focus-document : editor vid|did → editor
;;   设计：焦点是 vid；按 did 聚焦时取该文档的**第一个** view（可能不是你想要的那个）。
;;   用法：拖焦点必须先 editor-focus-view（精确 vid）；只有「聚焦某文档」时才用 document 版。
(show "(editor-focus (editor-focus-view e2 vid2))" (editor-focus (editor-focus-view e2 vid2)))
(show "(editor-focus (editor-focus-document e2 0))" (editor-focus (editor-focus-document e2 0)))

;; editor-close-view / editor-close-document : editor vid|did → editor
;;   设计：两个生命周期各自可关。关文档会连带关掉它的所有 view；关 view 只减视口。
;;         关闭后 id **不复用**（避免「关了又开」拿到同一个 id 的悬垂句柄）。
;;   用法：分屏关一个窗格用 close-view；buffer 关文档用 close-document。
(show "(editor-view-count (editor-close-view e2 vid2))" (editor-view-count (editor-close-view e2 vid2)))
(show "(editor-document-count (editor-close-document e2 did1))" (editor-document-count (editor-close-document e2 did1)))

;; 名字 / 定位 / 底层值
;; editor-document-name / editor-document-set-name : editor did [string] → string|editor
;;   设计：名字是应用元数据（文件名），core 不改文本、不入账本。
(show "(editor-document-name e2 0)" (editor-document-name e2 0))
(show "(editor-document-set-name e2 0 \"renamed\") → name" (editor-document-name (editor-document-set-name e2 0 "renamed") 0))
;; editor-document-view : editor did → (or/c vid #f)
;;   设计：did →「它有没有 view」；没有 view 的文档无法承载显示语义（命令会报错）。
;;   用法：程序编辑前检查；分屏时判断文档是否可见。
(show "(editor-document-view e2 0)" (editor-document-view e2 0))
;; editor-view-document-id : editor vid → did
;;   设计：vid → did 的逆向。视图看哪个文档。
;;   用法：知道在哪个窗格、想知道看的是哪个文档。
(show "(editor-view-document-id e2 0)" (editor-view-document-id e2 0))
;; editor-document / editor-document-buffer / editor-document-attrs : editor did → document|buffer|attrs
;;   设计：把底层值取出来做只读解析或传给底层函数；**不要**拿它自行构造编辑（走命令）。
(show "(editor-document e2 0)" (editor-document e2 0))
(show "(editor-document-buffer e2 0)" (editor-document-buffer e2 0))
(show "(editor-document-attrs e2 0)" (editor-document-attrs e2 0))
;; editor-view-buffer : editor vid → buffer（省一次 did 往返）
(show "(editor-view-buffer e2 0)" (editor-view-buffer e2 0))

;;; ===========================================================================
(header "2. 文本 / 位置 / 光标读（did / vid 分工）")
;;; ===========================================================================

;; 按 did 读文本：文档级，与焦点、视口无关。
;;   设计：文本属于 document，不属于 view —— 所以这些口收 did。
(show "(editor-document->string e2 0)" (editor-document->string e2 0))
(show "(editor-document->lines e2 0)" (editor-document->lines e2 0))
(show "(editor-document-line-count e2 0)" (editor-document-line-count e2 0))
(show "(editor-document-line-ref e2 0 0)" (editor-document-line-ref e2 0 0))
(show "(editor-document-line-length e2 0 0)" (editor-document-line-length e2 0 0))
(show "(editor-document-clamp-point e2 0 (point 9 9))" (editor-document-clamp-point e2 0 (P 9 9)))
(show "(editor-document-point->offset e2 0 (point 0 1))" (editor-document-point->offset e2 0 (P 0 1)))
(show "(editor-document-offset->point e2 0 1)" (editor-document-offset->point e2 0 1))
(show "(editor-document-range-text e2 0 (point 0 0) (point 0 2))" (editor-document-range-text e2 0 (P 0 0) (P 0 2)))
;; tick：版本戳。文本变只涨 text-tick；属性变只涨 attr-tick。
;;   设计：给前端做「变没变 / 要不要重画 / 脏标记」的廉价判断，不用深比较内容。
;;   用法：dirty? = text-tick ≠ 上次保存时的 tick。
(show "(editor-document-text-tick e2 0)" (editor-document-text-tick e2 0))
(show "(editor-document-attr-tick e2 0)" (editor-document-attr-tick e2 0))
(show "(editor-document-content-eq? e2 0 0)" (editor-document-content-eq? e2 0 0))

;; 光标 / 选区 / 尺寸：属于 **view**，所以收 vid。
;;   设计：同一个文档多个 view 各有光标；焦点糖（不带 vid）才用 focus。
(define ef (editor-focus-document e2 0))
(show "(editor-point (focus did 0))  # 焦点糖：焦点 view 的光标" (editor-point ef))
(show "(editor-view-point e2 0)     # 精确：view 0 的光标" (editor-view-point e2 0))
(show "(editor-primary (focus))     # 主选区（不靠位置比较）" (editor-primary ef))
(show "(editor-selections (focus))  # 全部选区" (editor-selections ef))
(show "(editor-selection-set-name (focus))  # 命名选区集名（#f=匿名）" (editor-selection-set-name ef))
(show "(editor-view-height e2 0)" (editor-view-height e2 0))
(show "(editor-view-width e2 0)" (editor-view-width e2 0))
(show "(editor-view-top-line e2 0)" (editor-view-top-line e2 0))
(show "(editor-view-mode e2 0)" (editor-view-mode e2 0))
(show "(editor-view-line-numbers? e2 0)" (editor-view-line-numbers? e2 0))

;;; ===========================================================================
(header "3. 编辑动作（值）：editor op 形状")
;;; ===========================================================================

;; 设计：编辑动作是**值**（函数），不是立即执行的调用。
;;   edit-* : … → (editor did selection → (or/c #f edit-desc))
;;   好处：同一个动作可配合 #:view / #:selection / #:reaction / #:record? 复用；
;;         缺省（未定义 action）就是 #f = 什么都不做。
;; 用法：喂给 editor-command / editor-view-edit / editor-document-edit-at。
(show "(edit-insert \"XY\")  + #:selection (caret (0,1))"
      (let-values ([(e _d1) (editor-command (editor-open "abc") (edit-insert "XY")
                                            #:selection (list (caret (P 0 1)))
                                            #:reaction 'leader #:record? #t)])
        (editor-document->string e 0)))
(show "(editor-edit e (edit-insert-char #\\Z))"
      (let-values ([(e _d2) (editor-edit (editor-open "abc") (edit-insert-char #\Z))]) (editor-document->string e 0)))
(show "(editor-edit e (edit-backspace))"
      (let-values ([(e _d3) (editor-edit (editor-set-point (editor-open "abc") (P 0 2)) (edit-backspace))]) (editor-document->string e 0)))
(show "(editor-edit e (edit-delete))"
      (let-values ([(e _d4) (editor-edit (editor-open "abc") (edit-delete))]) (editor-document->string e 0)))
(show "(editor-edit e (edit-newline))"
      (let-values ([(e _d5) (editor-edit (editor-open "abc") (edit-newline))]) (editor-document->string e 0)))
;; edit-splice : point point string → editor op（显式区间替换）
;;   设计：通用逃生门——给「程序化、已知区间」的替换，不走 buffer-op。
(show "(edit-splice (0,0) (0,3) \"XYZ\")"
      (let-values ([(e _d6) (editor-command (editor-open "abc") (edit-splice (P 0 0) (P 0 3) "XYZ")
                                            #:selection (list (caret (P 0 0))) #:reaction 'leader #:record? #t)])
        (editor-document->string e 0)))

;;; ===========================================================================
(header "4. 用户命令：编辑 / 撤销 / 重做")
;;; ===========================================================================

;; editor-edit : editor (editor op) → (values editor report)
;;   设计：**用户编辑**语义 = 焦点 view + reaction 'leader（光标推进到插入后）+ 记一步账。
;;         是 editor-command 的固定策略薄封装（策略见 §6）。
;;   用法：应用「打字 / 回车 / 退格」直接用这些；要做「程序编辑不打扰用户」用 §6 的 editor-command。
(define eu0 (editor-open "abc"))
(define-values (eu1 r-u1) (editor-edit eu0 (edit-insert "X")))
(show "(editor-document->string editor-edit)" (editor-document->string eu1 0))
;; change-report：本次命令「实际生效了什么」，给前端做增量。
;;   design：一个 change 可能被守卫拒、可能多条 desc 合并；report 是唯一权威的「生效结果」。
;;   用法：拿 texts/attrs 去做镜像同步、增量重绘；first-line/last-line 定位受影响行。
(show "change-report 首行" (change-report-first-line r-u1))
(show "change-report texts（施加顺序）" (change-report-texts r-u1))
(show "change-report attrs" (change-report-attrs r-u1))
;; 账本读口：能不能撤、能撤几步。did 缺省 = 焦点文档。
(show "(editor-document-can-undo? eu1)" (editor-document-can-undo? eu1))
(show "(editor-document-undo-depth eu1)" (editor-document-undo-depth eu1))

;; editor-undo / editor-redo : editor → (values editor report/#f)
;;   设计：账本在 document 上（同文档所有 view 共享历史）；一步 = 正反两串 change，
;;         撤销会把「编辑前的光标」也带回去。
;;   用法：撤销后 report 是逆 descs（可用来同步镜像文档）；#f = 没得撤。
(define-values (eu2 _d7) (editor-undo eu1))
(show "(editor-document->string editor-undo)" (editor-document->string eu2 0))
(define-values (eu3 _d8) (editor-redo eu2))
(show "(editor-document->string editor-redo)" (editor-document->string eu3 0))

;; editor-view-edit / -undo / -redo : 按 **vid**
;;   设计：用户命令的显式版——不读焦点、只作用目标视口。适合后台/多窗格。
(define ev0 (editor-open "abc"))
(define-values (ev1 _d9) (editor-view-edit ev0 0 (edit-insert "Y")))
(show "(editor-view-edit ev 0)" (editor-document->string ev1 0))
(define-values (ev2 _d10) (editor-view-undo ev1 0))
(show "(editor-view-undo ev 0)" (editor-document->string ev2 0))

;;; ===========================================================================
(header "5. 导航")
;;; ===========================================================================

;; 设计：导航是「用户命令」——移动光标 + ensure（保持可见）+ 同文档 follow 视图镜像。
;;   全部收 vid（显式），focus 糖收 focus。
;; 用法：方向键/翻页用它；只想算一个点（不改 view）用点算子（见下）。
(define en (editor-open "l0\nl1\nl2" 3 10))
(define e-n (editor-view-goto en 0 (P 1 1)))
(show "(editor-view-point after editor-view-goto (1,1))" (editor-view-point e-n 0))
(show "(editor-view-left)" (editor-view-point (editor-view-left e-n 0) 0))
(show "(editor-view-right)" (editor-view-point (editor-view-right e-n 0) 0))
(show "(editor-view-up)" (editor-view-point (editor-view-up e-n 0) 0))
(show "(editor-view-down)" (editor-view-point (editor-view-down e-n 0) 0))
(show "(editor-view-home)" (editor-view-point (editor-view-home e-n 0) 0))
(show "(editor-view-end)" (editor-view-point (editor-view-end e-n 0) 0))
(show "(editor-view-scroll 1) → top-line" (editor-view-top-line (editor-view-scroll e-n 0 1) 0))

;; 点算子（editor 级）：editor did/buffer 由 editor 解析，你只给 point。
;;   设计：把「怎么移动一个点」与「视图怎么反应」解耦；up/down 依赖视口几何（wrap 折行）。
;;   用法：扩选、加光标、算目标位置时用；它们不改任何 view。
(show "(editor-point-right en (point 0 0))" (editor-point-right en (P 0 0)))
(show "(editor-point-left en (point 1 0))" (editor-point-left en (P 1 0)))
(show "(editor-point-down en (point 0 0))" (editor-point-down en (P 0 0)))
(show "(editor-point-up en (point 2 0))" (editor-point-up en (P 2 0)))
(show "(editor-point-home en (point 1 2))" (editor-point-home en (P 1 2)))
(show "(editor-point-end en (point 0 0))" (editor-point-end en (P 0 0)))
;; focus 糖：editor-left/right/up/down/home/end/goto/scroll（作用于焦点 view）
(show "(editor-right) → point" (editor-point (editor-right (editor-focus-document en 0))))
(show "(editor-scroll 1) → top-line" (editor-top-line (editor-scroll (editor-focus-document en 0) 1)))

;;; ===========================================================================
(header "6. 程序面：editor-command（一个原语，策略全是参数）")
;;; ===========================================================================

;; 设计：core 只有**一个**编辑原语。不是「很多命令函数」，而是
;;       「一个原语 + 几个正交策略参数」，避免命令数量爆炸，也便于组合。
;;       op 是 editor op 值（§3）；以下都是数据：
;;         #:view       作用到哪个 vid（默认焦点）
;;         #:selection  编辑上下文（默认该 view 的选区集）
;;         #:attrs      属性计划（文本生效后求值；文本+属性一次换、一步账）
;;         #:trusted?   是否跳过 read-only 守卫
;;         #:reaction   'none 光标字面不动 | 'map 同文档各 view 映射 | 'leader 本 view 推进+ensure
;;         #:record?    'default 跟随文档策略 | #t | #f（整批记一步）
;;         #:pre-point  记账用的「编辑前光标」（撤销回到哪）
;;   用法：用户编辑用 editor-edit（= leader + default）；后台/程序编辑用 editor-command
;;         显式指定 #:selection + reaction 'none + #:record? #f，做到「不打扰用户」。
(define ec0 (editor-open "abcdef"))
(define-values (ec1 rc1) (editor-command ec0 (edit-insert "X")))
(show "默认：reaction 'none → 光标字面不动" (editor-point ec1))
(show "默认：文本变了" (editor-document->string ec1 0))
(show "'leader + #:selection 指定位置"
      (let-values ([(e _d11) (editor-command ec0 (edit-insert "Y")
                                             #:selection (list (caret (P 0 3)))
                                             #:reaction 'leader #:record? #t)])
        (list (editor-document->string e 0) (editor-point e))))
(show "#:trusted? #t 绕 read-only"
      (let-values ([(ed _d12) (editor-document-put-attr (editor-open "abc") 0 read-only-key 0 0 3 #t #:record? #f)])
        (editor-document->string (car (call-with-values
                                       (lambda () (editor-command ed (edit-insert-char #\X)
                                                                  #:selection (list (caret (P 0 1))) #:trusted? #t))
                                       list)) 0)))

;; editor-command-batch : editor change …
;;   设计：已经有现成 change（比如从别的文档 change-report 来的）时直接施加；
;;         与 editor-command 同一条漏斗，只是不经过 op→desc。
;;   用法：内容镜像同步（把 A 的 report 原样给 B）。
(define-values (ecb _d13) (editor-command-batch ec0 (edits->change (list (edit-desc (P 0 1) (P 0 1) "Q")))))
(show "editor-command-batch" (editor-document->string ecb 0))

;; editor-document-edit-at / -edit-at-batch : 程序编辑（收 did）
;;   设计：给「已知文档 + 位置」的程序化编辑糖：自动解析该文档的 vid，reaction 'none。
;;   用法：脚本/插件改文档；不想影响用户光标。
(define-values (eda _d14) (editor-document-edit-at ec0 0 (P 0 0) (edit-insert "P")))
(show "editor-document-edit-at" (editor-document->string eda 0))
(define-values (edab _d15) (editor-document-edit-at-batch ec0 0 (list (edit-desc (P 0 0) (P 0 0) "a")
                                                                      (edit-desc (P 0 1) (P 0 1) "b"))))
(show "editor-document-edit-at-batch" (editor-document->string edab 0))

;; editor-document-apply-edits : editor did (listof edit-desc) #:record? → (values editor report)
;;   设计：批量文本的显式入口（不带动画/光标）；比一条条 edit-at 快且只记一步。
(define-values (ede re) (editor-document-apply-edits ec0 0 (list (edit-desc (P 0 2) (P 0 2) "-"))))
(show "editor-document-apply-edits" (editor-document->string ede 0))
(show "report texts" (change-report-texts re))

;;; ===========================================================================
(header "7. 视图命令（收 vid；只动指定 view，不镜像、不抢焦点）+ focus 糖")
;;; ===========================================================================

;; 设计：程序面视图命令一律「显式 vid、只动这一个 view、不经过焦点、不触发同步」。
;;   focus 糖是同一套的镜像（作用于焦点 vid）。这样「精确控制」和「顺手操作」都有。
(define ev (editor-open "abcdef" 2 10))
(show "(editor-view-set-point ev 0 (point 0 3)) → point" (editor-view-point (editor-view-set-point ev 0 (P 0 3)) 0))
(show "(editor-view-set-selections ev 0 [caret0 caret3])"
      (editor-view-selections (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0))
(show "(editor-view-set-size ev 0 1 6) → (h w)"
      (let ([x (editor-view-set-size ev 0 1 6)]) (list (editor-view-height x 0) (editor-view-width x 0))))
(show "(editor-view-set-mode ev 0 'wrap)" (editor-view-mode (editor-view-set-mode ev 0 'wrap) 0))
(show "(editor-view-set-line-numbers ev 0 #t)" (editor-view-line-numbers? (editor-view-set-line-numbers ev 0 #t) 0))
(define evtop (editor-open "l0\nl1\nl2\nl3" 2 10))
(show "(editor-view-set-top-line evtop 0 2)" (editor-view-top-line (editor-view-set-top-line evtop 0 2) 0))
(show "(editor-view-set-left-col ev 0 2)" (editor-view-left-col (editor-view-set-left-col ev 0 2) 0))
(define evwrap (editor-view-set-mode (editor-open "abcdefghij" 2 4) 0 'wrap))
(show "(editor-view-set-top-seg evwrap 0 1)" (editor-view-top-seg (editor-view-set-top-seg evwrap 0 1) 0))
(show "(editor-view-collapse-selections ev 0) → count"
      (length (editor-view-selections (editor-view-collapse-selections
                                       (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0) 0)))
(show "(editor-view-map-points ev 0 右移)"
      (editor-view-point (editor-view-map-points ev 0 (lambda (p) (point-right (editor-view-buffer ev 0) p))) 0))
(show "(editor-view-map-primary ev 0 …)"
      (editor-view-primary (editor-view-map-primary (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0
                                                    (lambda (s) (selection (selection-anchor s) (P 0 5)))) 0))
(show "(editor-view-add-selection ev 0 (caret (0,4))) count"
      (length (editor-view-selections (editor-view-add-selection ev 0 (caret (P 0 4))) 0)))
(show "(editor-view-remove-selection ev 0 (caret (0,0))) count"
      (length (editor-view-selections (editor-view-remove-selection
                                       (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0
                                       (caret (P 0 0))) 0)))
(show "(editor-view-set-primary ev 0 …)"
      (editor-view-primary (editor-view-set-primary
                            (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0
                            (caret (P 0 3))) 0))
(show "(editor-view-set-primary-index ev 0 1)"
      (editor-view-primary-index (editor-view-set-primary-index
                                  (editor-view-set-selections ev 0 (list (caret (P 0 0)) (caret (P 0 3)))) 0 1) 0))
(show "(editor-view-selection-member? ev 0 (caret 0,0))"
      (editor-view-selection-member? ev 0 (caret (P 0 0))))
;; 裸写整个 window：读 window → window-* 算子 → put-window
;;   设计：给「一次改多个视图态」的组合口；put-window 校验 document 一致（换文档用 set-document）。
(show "(editor-view-put-window ev 0 (window-set-point (editor-view-window ev 0) (point 0 4)))"
      (editor-view-point (editor-view-put-window ev 0 (window-set-point (editor-view-window ev 0) (P 0 4))) 0))

;; focus 糖：与上面镜像，作用于焦点 view。
;;   设计：日常交互（按键）通常只关心焦点，用糖更短。
(show "(editor-set-point ev (point 0 3))" (editor-point (editor-set-point ev (P 0 3))))
(show "(editor-set-selections ev [..])" (editor-selections (editor-set-selections ev (list (caret (P 0 0)) (caret (P 0 2))))))
(show "(editor-set-size ev 1 6) → (h w)" (let ([x (editor-set-size ev 1 6)]) (list (editor-height x) (editor-width x))))
(show "(editor-set-mode ev 'wrap)" (editor-mode (editor-set-mode ev 'wrap)))
(show "(editor-set-line-numbers ev #t)" (editor-line-numbers? (editor-set-line-numbers ev #t)))
(show "(editor-add-selection ev (caret (0,5))) count"
      (length (editor-selections (editor-add-selection ev (caret (P 0 5))))))
(show "(editor-collapse-selections ev) count"
      (length (editor-selections (editor-collapse-selections
                                  (editor-set-selections ev (list (caret (P 0 0)) (caret (P 0 3))))))))

;; editor-view-set-document / editor-set-document : editor vid [did] → editor
;;   设计：换视口看的文档（不动文本、不动焦点）。窗口的 document 必须始终指向 editor 里的文档，
;;         所以换文档只能走这个口（editor-view-put-window 会拒绝不一致的 document）。
(define edoc (editor-open "doc0"))
(define-values (edoc2 didB) (editor-open-document edoc "docB" #:name "B" #:focus? #f))
(show "(editor-view-set-document edoc2 0 didB) → did" (editor-view-document-id (editor-view-set-document edoc2 0 didB) 0))
(show "(editor-set-document (focus) didB) → did" (editor-document-id (editor-set-document edoc2 didB)))
;; editor-view-set-sync : editor vid 'free|'follow → editor
;;   设计：同文档镜像策略槽——'follow 的 view 会在别的 view 编辑/滚动时自动跟（视口同步）。
(show "(editor-view-set-sync edoc2 0 'follow)" (editor-view-sync (editor-view-set-sync edoc2 0 'follow) 0))

;;; ===========================================================================
(header "8. 账本策略 / 清栈")
;;; ===========================================================================

;; 设计：历史策略是**文档属性**（默认开，可关）；命令可用 #:record? 覆盖它。
;;   这样派生 UI（树/状态栏）用 #:history? #f 不产生历史，而普通文档默认记。
(show "(editor-document-history-enabled? e0 0)" (editor-document-history-enabled? e0 0))
(define enoh (editor-open "abc" #:history? #f))
(show "(editor-document-history-enabled? #:history? #f)" (editor-document-history-enabled? enoh 0))
(define enoh1 (editor-set-history-enabled enoh #t))
(show "editor-set-history-enabled → #t" (editor-document-history-enabled? enoh1 0))
(show "(editor-document-can-undo? 编辑后)"
      (editor-document-can-undo? (car (call-with-values (lambda () (editor-edit enoh1 (edit-insert "X"))) list))))
(show "(editor-document-clear-history) → can-undo?"
      (editor-document-can-undo? (editor-document-clear-history enoh1) 0))
(show "(editor-view-clear-history enoh1 0) → redo-depth"
      (editor-document-redo-depth (editor-view-clear-history enoh1 0) 0))

;;; ===========================================================================
(header "9. 视口同步 link（可跨文档）")
;;; ===========================================================================

;; 设计：link 是**视口同步组名**（符号）。组内成员按「行固定、列按比例」互相跟随；
;;   与 sync 的区别：sync 是同一文档内镜像，link 可跨文档。
;;   设链时默认立即对齐（参考成员 = #:from → 焦点 → 组内第一个）。
(define lk0 (editor-open "l0\nl1\nl2\nl3" 2 10 #:name "A"))
(define-values (lk1 vidB) (editor-open-document lk0 "m0\nm1\nm2\nm3" 2 10 #:name "B" #:focus? #f))
(define lk2 (editor-link-views lk1 'pair (list 0 vidB)))
(show "(editor-view-link lk2 0)" (editor-view-link lk2 0))
(show "(editor-links lk2)" (editor-links lk2))
(define lk3 (editor-view-goto lk2 0 (P 3 0)))
(show "滚动 0 后两边 top-line" (list (editor-view-top-line lk3 0) (editor-view-top-line lk3 vidB)))
(show "(editor-view-unlink lk3 vidB) → link" (editor-view-link (editor-view-unlink lk3 vidB) vidB))

(printf "\neditor/1-edit.rkt 跑完（没有报错）。\n")
