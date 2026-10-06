#lang racket

(require "slot.rkt")

;;; lab-rebuild/ui/mode.rkt —— 输入转移状态（纯）
;;;
;;; 底部那条是**共享槽位**，只放两份文档：
;;;   空闲 / 前缀 → state 文档；有 prompt → input 文档（可编辑 / 确认都是它）。
;;; 切换只改一个 `mode` 值（#f | prompt | prefix）；布局 / 命令表都是静态的。
;;;
;;; 三种转移状态：
;;;   #f      空闲
;;;   prompt  要输入（续延回传值；见下）
;;;   prefix  前缀键（如 C-p）：下一键只能命中它自己的表，用完即退；不改底部槽位
;;;
;;; ⚠ 值回传：命令表是事件驱动、不是调用栈，Enter handler 的返回值没人接。
;;;   所以发起时把**续延**放进 prompt，提交时调用它：
;;;     input-begin  → app 存下 prompt、挂输入文档、聚焦输入视图
;;;     input-commit → 读文档值、app 先退出模态、再 (on-commit value)
;;;     input-cancel → app 先退出模态、再 (on-cancel)
;;;   「先退出再调续延」由 app 保证：续延里可能立刻发起下一个输入（链式）。
;;;
;;; 本文件不认识 vid / 布局：`mode-bottom-vid` / `mode-focus-vid` 直接收 vid，
;;; 由 app 的 panes registry 提供（不再是 slot 结构体）。
;;;
;;; 边界：
;;;   - 输入型 on-commit : string -> void；确认型 on-commit : boolean -> void。
;;;   - on-cancel 可 #f。
;;;   - 单槽：一次只允许一个 prompt（要嵌套再改栈）。

(provide (struct-out prompt)
         (struct-out prefix)
         (struct-out complete)
         (struct-out doc-pending)
         (struct-out docs)
         input-begin prefix-begin complete-begin docs-begin
         input-commit input-answer input-cancel
         prompt-document prompt-value
         mode-bottom-vid mode-focus-vid mode-tables)

;;; ================= 转移状态 =================

(struct prompt (label editable? prev-focus on-commit on-cancel) #:transparent)
;; label      : string（只读前缀）
;; editable?  : bool（#t 输入型 / #f 确认型）
;; prev-focus : vid / #f（发起前的焦点，结束后还原）
;; on-commit  : string -> any（输入型）/ boolean -> any（确认型）
;; on-cancel  : (-> any) / #f

;; 发起：只构造 prompt。app 负责存下它、挂文档、聚焦。
(define (input-begin label editable? prev-focus on-commit [on-cancel #f])
  (prompt label editable? prev-focus on-commit on-cancel))

;; prompt → 挂在底部槽位的输入文档。
(define (prompt-document p [value ""])
  (input->document (input (prompt-label p) (prompt-editable? p)) value))

(define (prompt-value p doc-string)
  (input-value (input (prompt-label p) (prompt-editable? p)) doc-string))

;; 提交（输入型）：读文档值 → 调续延。app 必须先退出模态再调本函数。
(define (input-commit p doc-string)
  (unless (prompt-editable? p)
    (error 'input-commit "确认型 prompt 用 input-answer"))
  (define k (prompt-on-commit p))
  (when k (k (prompt-value p doc-string))))

;; 提交（确认型）：y / n。
(define (input-answer p yes?)
  (when (prompt-editable? p)
    (error 'input-answer "输入型 prompt 用 input-commit"))
  (define k (prompt-on-commit p))
  (when k (k yes?)))

(define (input-cancel p)
  (define k (prompt-on-cancel p))
  (when k (k)))

;;; ================= 前缀键 =================

;; 前缀：标签（底部提示用）+ 下一键只查这张表；不挂文档、不动焦点。
(struct prefix (label tables) #:transparent)

(define (prefix-begin label tables) (prefix label tables))

;;; ================= 补全 =================

;; 补全菜单：不占底部槽位、不改焦点，只在渲染时叠一个弹层（见 app/render.rkt）。
;;   candidates : (listof string)   候选（有序）
;;   index      : 当前选中下标（在 [0, length) 内）
;;   start      : 前缀起点（point），接受时替换 [start, 光标) 为候选
;;   prev-focus : 发起补全时的编辑 view（接受 / 取消都看它）
;;   tables     : 本模态的键表（config/keys.rkt 提供）
;;   mods       : 查文档用的候选模块列表
;;   pool       : 本次补全会话的完整候选池（复用，避免每个字符重算 / 重解析）
;;   doc        : 当前选中项的文档（bluebox；#f = 没有 / 还没回来），弹层右侧展示
;;   doc-pending: 在途的异步文档请求（doc-pending / #f）；结果回来时按它做版本闸门
(struct complete (candidates index start prev-focus tables mods pool doc doc-pending) #:transparent)

(define (complete-begin candidates index start prev-focus tables mods pool doc doc-pending)
  (complete candidates index start prev-focus tables mods pool doc doc-pending))

;; 在途文档请求：
;;   id  : exact-nonnegative-integer   请求编号（结果按它匹配当前 mode）
;;   ver : document                    发起时的**不可变 document 值**（版本身份）
;; 文档是纯粹的「名字 + 模块表」的函数，与本 buffer 文本无关；但仍用 ver 做闸门，
;; 保证结果只装回它「出发时」的那份文档状态（eq? 即版本比较）。
(struct doc-pending (id ver) #:transparent)

;;; ================= 文档浮窗 =================

;; 只读文本浮窗（文档查询）：贴在光标下一行，Enter / Esc 关闭，上下滚动。
;;   vid    : 发起时的编辑 view（拿光标屏幕位置做锚点）
;;   point  : 发起时光标位置
;;   lines  : (vectorof string)   已按 width 折行好的内容行
;;   offset : 首行下标（在 [0, n - rows] 内）
;;   width  : 内容列宽（不含左右边框）
;;   rows   : 可见内容行数
;;   tables : 本模态的键表
(struct docs (vid point lines offset width rows tables) #:transparent)

(define (docs-begin vid point lines offset width rows tables)
  (docs vid point lines offset width rows tables))

;;; ================= 模式 → 槽位 / 焦点 / 命令表 =================

;; 底部槽位此刻挂哪个 vid（state-vid / input-vid 由 app 传）；只有 prompt 占 input。
(define (mode-bottom-vid m state-vid input-vid)
  (if (prompt? m) input-vid state-vid))

;; prompt 激活时焦点该在输入视图；空闲 / 前缀 → #f（不动焦点）。
(define (mode-focus-vid m input-vid)
  (and (prompt? m) input-vid))

;; 模态要额外叠的命令表（prompt 输入/确认/前缀）。
(define (mode-tables m edit-table confirm-table)
  (cond [(not m) '()]
        [(prompt? m) (if (prompt-editable? m) (list edit-table) (list confirm-table))]
        [(prefix? m) (prefix-tables m)]
        [(complete? m) (list (complete-tables m))]
        [(docs? m) (list (docs-tables m))]
        [else '()]))
