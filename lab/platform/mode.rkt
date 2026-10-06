#lang racket

(require "slot.rkt"
         "keymap.rkt")

;;; lab-rebuild/platform/mode.rkt —— 输入转移状态 + mode 注册表（平台核心）
;;;
;;; 底部那条是**共享槽位**：空闲显示 state，输入时切成 input 文档，结束切回。
;;; 切换只改一个 `mode` 值；布局 / 命令表都是静态的。
;;;
;;; 平台内置两种 mode：
;;;   prompt  要输入（续延回传值；输入型 / 确认型）
;;;   prefix  前缀键（如 C-p）：下一键只能命中它自己的表，用完即退
;;;
;;; 功能模态（补全菜单 / 文档浮窗 / …）**不写死在这里**，而是通过 mode 注册表
;;; 注册一个 `mode-type`：声明怎么匹配、带哪些键表、占哪个底部槽位、要不要抢焦点、
;;; 是否独占（不回落）、是否一次性（处理完即退）。平台只按注册表回答这几个问题，
;;; 于是「有哪些模态」对平台是开放的。
;;;
;;; 值回传：命令表是事件驱动、不是调用栈，Enter handler 的返回值没人接。
;;; 所以发起时把**续延**放进 prompt，提交时调用它：
;;;     input-begin  → app 存下 prompt、挂输入文档、聚焦输入视图
;;;     input-commit → 读文档值、app 先退出模态、再 (on-commit value)
;;;     input-cancel → app 先退出模态、再 (on-cancel)

(provide (struct-out prompt)
         (struct-out prefix)
         input-begin prefix-begin
         input-commit input-answer input-cancel
         prompt-document prompt-value
         ;; mode type 注册表
         (struct-out mode-type)
         mode-type-register! mode-type-unregister! mode-type-ref mode-types
         mode-active-type
         mode-tables mode-bottom-vid mode-focus-vid
         mode-exclusive? mode-transient?
         mode-keymap-name)

;;; ================= 内置转移状态 =================

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

;; 前缀：标签（底部提示用）+ 下一键只查这张表；不挂文档、不动焦点。
;; kind 是可选的**用途标签**（如 'pane-move），让 app 层知道这个前缀该不该对鼠标点击做特殊处理。
(struct prefix (label tables kind) #:transparent)

(define (prefix-begin label tables [kind #f]) (prefix label tables kind))

;;; ================= mode type 注册表 =================
;;;
;;; mode 值本身是 opaque 的（prompt / prefix / 功能模态各自的 struct）。
;;; 平台通过已注册的 mode-type 回答「这个 mode 怎么参与平台」：
;;;
;;;   match?      : mode -> boolean          是不是我的模态
;;;   tables      : mode -> (listof keymap)  本模态叠在最上层的键表
;;;   bottom      : mode -> 'state | 'input  底部槽位挂哪个文档
;;;   focus       : mode -> #f | 'input      要不要把焦点移到输入视图
;;;   exclusive?  : boolean                  只查它的表，不回落 did / global
;;;   transient?  : boolean                  处理一个事件后自动退出到 #f
;;;
;;; 注册顺序 = 匹配优先级（先注册先匹配）；predicate 之间应互斥。

(define mode-type-list '())

(struct mode-type (name match? tables bottom focus exclusive? transient?) #:transparent)
;; name : symbol（唯一，重复注册会替换）

(define (mode-type-register! mt)
  (unless (mode-type? mt) (error 'mode-type-register! "需要 mode-type，得到 ~a" mt))
  (set! mode-type-list
        (append (filter-not (lambda (x) (eq? (mode-type-name x) (mode-type-name mt))) mode-type-list)
                (list mt)))
  mt)

(define (mode-type-unregister! name)
  (set! mode-type-list (filter-not (lambda (x) (eq? (mode-type-name x) name)) mode-type-list))
  (void))

(define (mode-types) mode-type-list)

(define (mode-type-ref name)
  (for/first ([mt (in-list mode-type-list)] #:when (eq? (mode-type-name mt) name)) mt))

;; 当前 mode 值对应的 mode-type（#f = 空闲 / 无人认领）。
(define (mode-active-type m)
  (and m
       (for/first ([mt (in-list mode-type-list)] #:when ((mode-type-match? mt) m)) mt)))

;;; ================= mode → 槽位 / 焦点 / 命令表 =================

(define (mode-tables m)
  (define mt (mode-active-type m))
  (if mt ((mode-type-tables mt) m) '()))

(define (mode-bottom-vid m state-vid input-vid)
  (define mt (mode-active-type m))
  (if (and mt (eq? 'input ((mode-type-bottom mt) m))) input-vid state-vid))

(define (mode-focus-vid m input-vid)
  (define mt (mode-active-type m))
  (and mt (eq? 'input ((mode-type-focus mt) m)) input-vid))

(define (mode-exclusive? m)
  (define mt (mode-active-type m))
  (and mt (mode-type-exclusive? mt) #t))

(define (mode-transient? m)
  (define mt (mode-active-type m))
  (and mt (mode-type-transient? mt) #t))

;; 某些模态的键表来自命名 keymap（如 prompt 用 'input-edit / 'confirm）。
;; 平台在这里声明「命名 keymap 的用途」常量，避免散落字符串。
(define prompt-input-keymap 'input-edit)
(define prompt-confirm-keymap 'confirm)

(define (mode-keymap-name kind)
  (case kind
    [(prompt-input) prompt-input-keymap]
    [(prompt-confirm) prompt-confirm-keymap]
    [else (error 'mode-keymap-name "未知 kind: ~a" kind)]))

;;; ================= 注册内置 mode =================

(void
 (mode-type-register!
  (mode-type 'prompt
             prompt?
             (lambda (m)
               (list (keymap-ensure! (if (prompt-editable? m)
                                         prompt-input-keymap
                                         prompt-confirm-keymap))))
             (lambda (_) 'input)
             (lambda (_) 'input)
             #f      ; 不独占：其余按键落回普通编辑表（不阻塞输入）
             #f)))   ; 不自动退出：提交 / 取消由命令或事件循环决定

(void
 (mode-type-register!
  (mode-type 'prefix
             prefix?
             (lambda (m) (prefix-tables m))
             (lambda (_) 'state)
             (lambda (_) #f)
             #t      ; 独占：只查它自己的表，不按 did 回落
             #t)))   ; 一次性：处理完一个事件就退出
