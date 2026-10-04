#lang racket

(require "input-doc.rkt")

;;; lab-rebuild/mode.rkt —— 输入转移状态（骨架）
;;;
;;; 目的：底部那条是**共享槽位**，只放两份文档：
;;;   空闲 → state 文档；有 prompt → input 文档（可编辑 / 确认都是它）。
;;; 切换只改一个 `mode` 值（#f | prompt），布局 / 命令表都是静态的。
;;;
;;; 三个东西分离：
;;;   input-doc  文档（纯，复用）
;;;   prompt     这次输入是什么 + 值往哪去（本文件）
;;;   业务续延   发起方给，模态只管调用
;;;
;;; ⚠ 值回传：命令表是事件驱动、不是调用栈，Enter handler 的返回值没人接。
;;;   所以发起时把**续延**放进 prompt，提交时调用它：
;;;     input-begin  → app 存下 prompt、挂输入文档、聚焦输入视图
;;;     input-commit → 读文档值、app 先退出模态、再 (on-commit value)
;;;     input-cancel → app 先退出模态、再 (on-cancel)
;;;   「先退出再调续延」由 app 保证：续延里可能立刻发起下一个输入（链式）。
;;;
;;; 边界：
;;;   - 输入型 on-commit : string -> void；确认型 on-commit : boolean -> void。
;;;   - on-cancel 可 #f。
;;;   - 单槽：一次只允许一个 prompt（要嵌套再改栈）。

(provide (struct-out slot)
         (struct-out prompt)
         input-begin
         input-commit input-answer input-cancel
         prompt-document prompt-value
         mode? mode-bottom-vid mode-focus-vid mode-tables)

;;; ================= 共享槽位 =================

;; 底部槽位的两个候选 vid（都是常驻 view，谁进 panes 由 mode 决定）。
(struct slot (state-vid input-vid) #:transparent)

;;; ================= 转移状态 =================

(struct prompt (label editable? prev-focus on-commit on-cancel) #:transparent)
;; label      : string（只读前缀）
;; editable?  : bool（#t 输入型 / #f 确认型）
;; prev-focus : vid / #f（发起前的焦点，结束后还原）
;; on-commit  : string -> any（输入型）/ boolean -> any（确认型）
;; on-cancel  : (-> any) / #f

(define (mode? m) (or (not m) (prompt? m)))

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

;;; ================= 模式 → 槽位 / 焦点 / 命令表 =================

;; 底部槽位此刻挂哪个 vid。
(define (mode-bottom-vid m slot)
  (if m (slot-input-vid slot) (slot-state-vid slot)))

;; 模态激活时焦点该在哪；空闲 → #f（表示不动 / 还原）。
(define (mode-focus-vid m slot)
  (and m (slot-input-vid slot)))

;; 要挂到输入 did 上的表（输入型 / 确认型）。列表形态，直接喂 command-set-set-doc。
(define (mode-tables m edit-table confirm-table)
  (cond [(not m) '()]
        [(prompt-editable? m) (list edit-table)]
        [else (list confirm-table)]))
